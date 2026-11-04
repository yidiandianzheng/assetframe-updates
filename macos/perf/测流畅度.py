#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V261023.9 流畅度基线测量（只读，不改 App、不写生产库）。

四项指标各跑 --repeat 次，取中位数：
  首屏      冷启动 / 热启动下，从进程起来到预览管线排空（缩略图全部出现）的耗时
  帧率      快速滚动 10 秒，外部探针测窗口内容更新率 + App 内主循环 tick 间隔（双口径）
  大图      CLI 回放「打开大图 / 逐张切换」的请求到就绪耗时
  筛选      CLI 回放「改搜索词」的请求到就绪耗时
  文件夹    点侧栏文件夹行，从点击到预览管线排空的耗时（同时读回 scope 证明真的换了文件夹）

用法：
  python3 测流畅度.py --qa-root /tmp/assetframe-qa.perf.XXXXXX [--repeat 3] [--only 首屏,帧率] [--out 报告.json]

前置：先用 建隔离图库.py 造好隔离根，并把 App 放到 <QA根>/App/向量·素仓.app。
"""
import argparse
import datetime
import json
import os
import statistics
import subprocess
import sys
import time

PERF_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(PERF_DIR, "..", ".."))
CLI = os.path.join(REPO, "macos", "CLI", "assetframe")
APP_BINARY = "App/向量·素仓.app/Contents/MacOS/AssetFrame"
DRIVER = os.path.join(PERF_DIR, "bin", "界面驱动")
PROBE = os.path.join(PERF_DIR, "bin", "帧率探针")
HELPERS = [("界面驱动", "界面驱动.swift"), ("帧率探针", "帧率探针.swift"), ("校准动画", "校准动画.swift")]


def log(message):
    print(message, file=sys.stderr, flush=True)


def build_helpers():
    os.makedirs(os.path.join(PERF_DIR, "bin"), exist_ok=True)
    for name, source in HELPERS:
        target = os.path.join(PERF_DIR, "bin", name)
        if os.path.exists(target) and os.path.getmtime(target) > os.path.getmtime(os.path.join(PERF_DIR, source)):
            continue
        log("编译 %s" % name)
        result = subprocess.run(["xcrun", "swiftc", "-O", os.path.join(PERF_DIR, source), "-o", target],
                                capture_output=True, text=True)
        if result.returncode != 0 or not os.path.exists(target):
            raise SystemExit("编译 %s 失败：\n%s" % (name, result.stderr[-2000:]))


def cli(qa_root, *words, timeout=20):
    command = [sys.executable, CLI, *words, "--endpoint", os.path.join(qa_root, "CLI", "endpoint.json"), "--json",
               "--timeout", str(timeout)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 15)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError("CLI %s 无输出：%s" % (" ".join(words), (result.stderr or result.stdout)[-400:]))
    if not payload.get("ok"):
        raise RuntimeError("CLI %s 失败：%s" % (" ".join(words), payload.get("error")))
    return payload["result"]


def driver(*words):
    result = subprocess.run([DRIVER, *[str(w) for w in words]], capture_output=True, text=True, timeout=180)
    lines = [json.loads(l) for l in result.stdout.splitlines() if l.strip().startswith("{")]
    return lines


def rss_kb(pid):
    try:
        return int(subprocess.run(["ps", "-p", str(pid), "-o", "rss="], capture_output=True, text=True).stdout.strip())
    except ValueError:
        return 0


def median(values, digits=1):
    return round(statistics.median(values), digits) if values else None


def qa_pids(qa_root):
    """列出仍在本隔离根上运行的 App 实例 pid。"""
    try:
        listing = subprocess.run(["ps", "-Ao", "pid,command"], capture_output=True, text=True).stdout
    except OSError:
        return []
    # ps 会把包名里的非 ASCII 转义成 M-x 形式，只比对到 ASCII 的 /App/ 前缀。
    prefix = os.path.join(qa_root, "App") + "/"
    found = []
    for line in listing.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(prefix):
            found.append(int(parts[0]))
    return found


def reset_browse(qa_root, kinds=("图片",)):
    """把浏览状态恢复到测量起点。App 退出时会写回 scope/scrollY，不重置的话第 2、3 次
    会从上一次的位置继续，测出来的就不是同一条起点线。"""
    registry = json.load(open(os.path.join(qa_root, "libraries.json"), encoding="utf-8"))
    path = os.path.join(qa_root, "browse-%s.json" % registry["currentID"])
    with open(path, encoding="utf-8") as handle:
        browse = json.load(handle)
    browse["scope"] = "all"
    browse["search"] = ""
    browse.setdefault("filter", {})["kinds"] = list(kinds)
    browse["scrollY"] = 0
    browse["selected"] = []
    browse.pop("scrollAnchor", None)
    browse.pop("focused", None)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(browse, handle, ensure_ascii=False, indent=1)


class Session:
    """一个隔离 App 实例的启动—等待—关闭周期。"""
    def __init__(self, qa_root, trace=True):
        self.qa_root = qa_root
        self.trace = trace
        self.process = None
        self.pid = None
        self.window = None
        self.launch_wall = None

    def start(self, settle_timeout=120):
        environment = dict(os.environ, ASSETFRAME_QA_DATA_ROOT=self.qa_root)
        if self.trace:
            environment["ASSETFRAME_PERF_TRACE"] = "1"
        cli_dir = os.path.join(self.qa_root, "CLI")
        endpoint = os.path.join(cli_dir, "endpoint.json")
        # 上一个实例没退干净时，CLI server.lock 会让新实例起不了服务端，这里先收尾。
        for pid in qa_pids(self.qa_root):
            subprocess.run(["kill", "-TERM", str(pid)])
        deadline = time.time() + 20
        while time.time() < deadline and qa_pids(self.qa_root):
            time.sleep(0.3)
        for stale in ("endpoint.json", "server.lock"):
            path = os.path.join(cli_dir, stale)
            if os.path.exists(path):
                os.remove(path)
        log_path = os.path.join(self.qa_root, "launch.log")
        with open(log_path, "a", encoding="utf-8") as handle:
            self.launch_wall = time.time()
            self.process = subprocess.Popen([os.path.join(self.qa_root, APP_BINARY)], stdout=handle, stderr=handle,
                                            env=environment)
        self.pid = self.process.pid
        deadline = time.time() + settle_timeout
        while time.time() < deadline:
            if os.path.exists(endpoint):
                try:
                    if cli(self.qa_root, "status").get("pid") == self.pid:
                        break
                except Exception:
                    pass
            time.sleep(0.05)
        else:
            tail = subprocess.run(["tail", "-c", "400", log_path], capture_output=True, text=True).stdout.strip()
            raise RuntimeError("App 起来后 CLI 连不上（pid %s），启动日志尾部：%s" % (self.pid, tail))
        return self

    def status(self):
        return cli(self.qa_root, "status")

    def wait_settled(self, timeout=120, interval=0.02):
        """等到预览管线排空且界面不忙；返回结束时刻（epoch 秒）。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            state = self.status()
            pipeline = state.get("previewPipeline") or {}
            workspace = state.get("workspace") or {}
            store = state.get("store") or {}
            if (not state.get("busy") and not store.get("loading") and not workspace.get("queryPending")
                    and all(int(v) == 0 for v in pipeline.values())):
                return time.time(), state
            time.sleep(interval)
        raise RuntimeError("等待就绪超时（pid %s）" % self.pid)

    def prepare_background(self, width=1440, height=900):
        """安静模式：取消隐藏并把窗口固定到统一尺寸，但不 activate、不提到最前，焦点留在用户那边。"""
        driver("unhide", "--pid", self.pid)
        driver("setframe", "--pid", self.pid, "--x", 0, "--y", 30, "--width", width, "--height", height)
        time.sleep(1.0)

    def frontmost(self):
        result = subprocess.run(["osascript", "-e",
                                 'tell application "System Events" to get name of first application process whose frontmost is true'],
                                capture_output=True, text=True)
        return result.stdout.strip()

    def raise_window(self, attempts=6):
        """取消隐藏并提到最前，返回主窗口的位置与尺寸（点）。
        点击和滚动都按屏幕坐标投递，所以窗口必须真的在最前，否则事件会打到别的 App 上。"""
        main = None
        for _ in range(attempts):
            main = self._raise_once()
            if main is not None and self.frontmost() == "AssetFrame":
                return main
            time.sleep(0.5)
        raise RuntimeError("无法把隔离实例放到最前（当前最前：%s）" % self.frontmost())

    def _raise_once(self):
        lines = driver("raise", "--pid", self.pid)
        main = next((w for w in lines if w.get("raised") and w.get("width", 0) > 800), None)
        if not main:
            return None
        time.sleep(0.6)
        self.window = main
        return main

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        time.sleep(0.8)


def trace_events(qa_root):
    path = os.path.join(qa_root, "browse-metrics.jsonl")
    if not os.path.isfile(path):
        return []
    events = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return events


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * (len(ordered) - 1)))]


def main_loop_stats(events, start, end):
    ticks = [e["interval_ms"] for e in events if e.get("event") == "main_loop_tick" and start <= e.get("wall_time", 0) <= end]
    if not ticks:
        return None
    return {
        "samples": len(ticks),
        "median_interval_ms": round(statistics.median(ticks), 2),
        "p95_interval_ms": round(percentile(ticks, 0.95), 2),
        "p99_interval_ms": round(percentile(ticks, 0.99), 2),
        "max_interval_ms": round(max(ticks), 2),
        "gaps_over_33ms": sum(1 for t in ticks if t > 33),
        "gaps_over_100ms": sum(1 for t in ticks if t > 100),
        "effective_fps_from_median": round(1000 / statistics.median(ticks), 2),
        "effective_fps_from_p99": round(1000 / percentile(ticks, 0.99), 2),
    }


def event_durations(events, name, start, end):
    return [round(e["duration_ms"], 2) for e in events
            if e.get("event") == name and "duration_ms" in e and start <= e.get("wall_time", 0) <= end]


def event_counts(events, names, start, end):
    return {name: sum(1 for e in events if e.get("event") == name and start <= e.get("wall_time", 0) <= end)
            for name in names}


def scenario_first_screen(qa_root, repeat):
    results = []
    for mode in ("冷启动", "热启动"):
        runs = []
        for index in range(repeat):
            if mode == "冷启动":
                cache = os.path.join(qa_root, "PreviewCache")
                subprocess.run(["rm", "-rf", cache], check=False)
            reset_browse(qa_root)
            session = Session(qa_root).start()
            session.prepare_background()
            settle_end, state = session.wait_settled(timeout=180)
            elapsed_ms = (settle_end - session.launch_wall) * 1000
            events = trace_events(qa_root)
            runs.append({
                "run": index + 1,
                "elapsed_ms": round(elapsed_ms, 1),
                "visible_count": (state.get("workspace") or {}).get("visibleCount"),
                "resident_mb": round(rss_kb(session.pid) / 1024, 1),
                "last_open_seconds": state.get("lastOpenSeconds"),
                "query_and_sort_ms": event_durations(events, "query_and_sort", session.launch_wall, settle_end),
                "gallery_snapshot_ms": event_durations(events, "gallery_snapshot_complete", session.launch_wall, settle_end),
                "card_host_create": event_counts(events, ["card_host_create"], session.launch_wall, settle_end)["card_host_create"],
                "gallery_apply": event_counts(events, ["gallery_apply"], session.launch_wall, settle_end)["gallery_apply"],
            })
            session.stop()
            log("首屏 %s #%d %.0f ms" % (mode, index + 1, elapsed_ms))
        results.append({"mode": mode, "runs": runs, "median_elapsed_ms": median([r["elapsed_ms"] for r in runs])})
    return {"name": "首屏缩略图全部出现耗时", "unit": "ms", "results": results}


def scenario_scroll_fps(qa_root, repeat, seconds, dy, interval, capture_width, gallery_fx=0.58, gallery_fy=0.78):
    runs = []
    for index in range(repeat):
        reset_browse(qa_root)
        session = Session(qa_root).start()
        session.prepare_background()
        session.wait_settled(timeout=180)
        window = session.raise_window()
        time.sleep(3)  # 让首屏解码彻底排空后再开测
        session.wait_settled(timeout=60)
        probe_out = os.path.join(qa_root, "probe-scroll-%d.jsonl" % (index + 1))
        if os.path.exists(probe_out):
            os.remove(probe_out)
        probe = subprocess.Popen([PROBE, "--window", str(window["id"]), "--seconds", str(seconds + 2),
                                  "--capture-width", str(capture_width), "--fps", "60", "--out", probe_out],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(1.2)
        scroll = driver("scroll", "--window", window["id"], "--dy", dy,
                        "--steps", int(round(seconds / interval)), "--interval", interval,
                        "--fx", gallery_fx, "--fy", gallery_fy)[0]
        stdout, stderr = probe.communicate(timeout=60)
        summary = json.loads(stdout.strip().splitlines()[-1]) if stdout.strip() else {"probe_error": stderr[-300:]}
        events = trace_events(qa_root)
        start, end = scroll["start_wall"], scroll["end_wall"]
        runs.append({
            "run": index + 1,
            "window": {"id": window["id"], "width": window["width"], "height": window["height"]},
            "scroll": {"events": scroll["posted_scrolls"], "dy_each": scroll["dy_each"],
                       "interval_s": interval, "span_px": scroll["posted_scrolls"] * scroll["dy_each"],
                       "start_wall": start, "end_wall": end},
            "probe": summary,
            "main_loop": main_loop_stats(events, start, end),
            "trace_events": event_counts(events, ["card_host_create", "gallery_prefetch_schedule", "scroll_bounds",
                                                  "gallery_apply", "selection_view_commit"], start, end),
            "trace_durations_ms": {name: event_durations(events, name, start, end)
                                   for name in ("gallery_apply", "gallery_snapshot_complete")},
            "scroll_bounds_y": [round(e["y"]) for e in events if e.get("event") == "scroll_bounds" and start <= e["wall_time"] <= end],
        })
        session.stop()
        log("帧率 #%d avg_fps=%s delivered_fps=%s 主循环中位间隔=%sms" % (
            index + 1, summary.get("avg_fps"), summary.get("delivered_fps"),
            (runs[-1]["main_loop"] or {}).get("median_interval_ms")))
    medians = {
        "avg_fps": median([r["probe"].get("avg_fps") for r in runs if r["probe"].get("avg_fps") is not None], 2),
        "delivered_fps": median([r["probe"].get("delivered_fps") for r in runs], 2),
        "worst1pct_fps": median([r["probe"].get("worst1pct_fps") for r in runs if r["probe"].get("worst1pct_fps") is not None], 2),
        "p99_interval_ms": median([r["probe"].get("p99_interval_ms") for r in runs if r["probe"].get("p99_interval_ms") is not None], 2),
        "main_loop_median_interval_ms": median([r["main_loop"]["median_interval_ms"] for r in runs if r["main_loop"]], 2),
        "main_loop_p99_interval_ms": median([r["main_loop"]["p99_interval_ms"] for r in runs if r["main_loop"]], 2),
    }
    return {"name": "快速滚动帧率", "unit": "fps / ms", "scroll_seconds": seconds, "runs": runs, "medians": medians}


def write_scenario(path, steps):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"steps": steps}, handle, ensure_ascii=False, indent=1)
    return path


def run_cli_measure(qa_root, name, steps, repeat, scratch):
    scenario_path = write_scenario(os.path.join(scratch, "场景-%s.json" % name), steps)
    report_path = os.path.join(scratch, "measure-%s-%d.json" % (name, int(time.time() * 1000)))
    if os.path.exists(report_path):
        os.remove(report_path)
    result = subprocess.run([sys.executable, CLI, "measure", "--scenario", scenario_path, "--output", report_path,
                             "--repeat", str(repeat), "--endpoint", os.path.join(qa_root, "CLI", "endpoint.json"),
                             "--json", "--timeout", "30"], capture_output=True, text=True, timeout=900)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"error": (result.stderr or result.stdout)[-500:], "scenario": steps}
    if not payload.get("ok"):
        return {"error": payload.get("error"), "scenario": steps}
    report = json.load(open(report_path, encoding="utf-8"))
    by_command = {}
    for sample in report["samples"]:
        by_command.setdefault(sample["command"], []).append(sample)
    summary = {}
    for command, samples in by_command.items():
        totals = sorted(s["total_ms"] for s in samples)
        summary[command] = {
            "samples": len(totals),
            "median_total_ms": round(statistics.median(totals), 1),
            "min_total_ms": round(totals[0], 1),
            "max_total_ms": round(totals[-1], 1),
            "p95_total_ms": round(percentile(totals, 0.95), 1),
            "median_settle_ms": round(statistics.median([s["settle_ms"] for s in samples]), 1),
            "median_request_ms": round(statistics.median([s["request_ms"] for s in samples]), 1),
        }
    return {"passed": report["passed"], "completion_scope": report["completionScope"], "steps": steps,
            "per_command": summary,
            "samples": [{k: s[k] for k in ("repeat", "step", "command", "total_ms", "settle_ms", "visibleCount")}
                        for s in report["samples"]]}


def scenario_preview(qa_root, repeat, scratch):
    listing = cli(qa_root, "list", "--kind", "图片", "--limit", "8")
    items = listing.get("items") or listing.get("materials") or []
    ids = [item.get("id") for item in items if item.get("id")][:6]
    if len(ids) < 4:
        raise RuntimeError("取不到足够的图片 ID：%s" % json.dumps(listing, ensure_ascii=False)[:300])
    steps = [{"command": "preview", "id": ids[0]}] + [{"command": "focus", "id": ids[i]} for i in range(1, len(ids))]
    result = run_cli_measure(qa_root, "大图", steps, repeat, scratch)
    result["ids"] = ids
    return {"name": "打开大图与逐张切换耗时", "unit": "ms", "detail": result}


def scenario_search(qa_root, repeat, scratch):
    steps = [{"command": "search", "query": "香万家"}, {"command": "search", "query": "包装"},
             {"command": "search", "query": "VI"}, {"command": "search", "query": ""}]
    result = run_cli_measure(qa_root, "筛选", steps, repeat, scratch)
    return {"name": "改筛选条件（搜索词）耗时", "unit": "ms", "detail": result}


def scenario_folder_switch(qa_root, repeat, rows, scratch):
    """按侧栏文件夹行（AXPress，不抢焦点、不用屏幕坐标），测「切换 → 预览管线排空」；读回 scope 证明范围真的换了。"""
    reset_browse(qa_root)
    session = Session(qa_root).start()
    session.prepare_background()
    session.wait_settled(timeout=180)
    runs = []
    for index in range(repeat):
        per_point = []
        for label in rows:
            before = session.status()
            settle_start = time.time()
            pressed = driver("press", "--pid", session.pid, "--text", label)[0]
            if not pressed.get("pressed"):
                per_point.append({"folder": label, "error": "AXPress 没成功：%s" % json.dumps(pressed, ensure_ascii=False)[:220]})
                continue
            try:
                settle_end, after = session.wait_settled(timeout=90)
            except RuntimeError as error:
                per_point.append({"folder": label, "error": str(error)})
                continue
            elapsed_ms = (settle_end - settle_start) * 1000
            events = trace_events(qa_root)
            per_point.append({
                "folder": label, "pressed_label": pressed.get("label"),
                "elapsed_ms": round(elapsed_ms, 1),
                "scope_before": before["browse"].get("scope"),
                "scope_after": after["browse"].get("scope"),
                "visible_before": (before.get("workspace") or {}).get("visibleCount"),
                "visible_after": (after.get("workspace") or {}).get("visibleCount"),
                "query_and_sort_ms": event_durations(events, "query_and_sort", settle_start, settle_end),
                "gallery_snapshot_ms": event_durations(events, "gallery_snapshot_complete", settle_start, settle_end),
                "card_host_create": event_counts(events, ["card_host_create"], settle_start, settle_end)["card_host_create"],
            })
            log("文件夹 %s #%d %.0f ms（%s → %s）" % (label, index + 1, elapsed_ms,
                                                  per_point[-1]["visible_before"], per_point[-1]["visible_after"]))
        runs.append({"run": index + 1, "folders": per_point})
    session.stop()
    changed = [p for r in runs for p in r["folders"] if p.get("visible_after") != p.get("visible_before")]
    medians = {}
    for label in rows:
        values = [p["elapsed_ms"] for r in runs for p in r["folders"] if p.get("folder") == label and "elapsed_ms" in p]
        medians[label] = median(values)
    return {"name": "切换文件夹耗时", "unit": "ms", "runs": runs, "medians": medians,
            "drive": "AXPress（辅助功能按键，不需要窗口在最前）",
            "clicks_that_changed_result": len(changed), "total_clicks": sum(len(r["folders"]) for r in runs)}


def calibrate_probe(qa_root, seconds=5):
    """用一个 60Hz 动画窗口证明探针自身的上限，避免把探针的采样上限当成 App 的帧率。"""
    animation = os.path.join(PERF_DIR, "bin", "校准动画")
    if not os.path.exists(animation):
        return None
    process = subprocess.Popen([animation, "--seconds", str(seconds + 3)], stdout=subprocess.PIPE, text=True)
    first = json.loads(process.stdout.readline())
    time.sleep(0.6)
    probe = subprocess.run([PROBE, "--window", str(first["window"]), "--seconds", str(seconds),
                            "--capture-width", "640", "--fps", "60"], capture_output=True, text=True, timeout=90)
    process.wait(timeout=30)
    summary = json.loads(probe.stdout.strip().splitlines()[-1])
    return {"animation_ticks_expected": int(seconds * 60), "delivered_fps": summary["delivered_fps"],
            "avg_fps": summary["avg_fps"], "median_interval_ms": summary["median_interval_ms"],
            "note": "校准窗口按 1/60 秒改一次图层内容；探针在这里能采到的帧率就是本次测量的上限"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qa-root", required=True)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--only", default="首屏,帧率,大图,筛选,文件夹")
    parser.add_argument("--scroll-seconds", type=float, default=10)
    parser.add_argument("--scroll-dy", type=int, default=-80,
                        help="每次滚轮像素，负值才是往下滚（实测 scrollY 会随之增大）")
    parser.add_argument("--scroll-interval", type=float, default=0.025)
    parser.add_argument("--capture-width", type=int, default=1280)
    parser.add_argument("--gallery-fx", type=float, default=0.58, help="滚动点横坐标在窗口内的比例（图库区）")
    parser.add_argument("--gallery-fy", type=float, default=0.78, help="滚动点纵坐标在窗口内的比例（图库区）")
    parser.add_argument("--folder", action="append", default=[],
                        help="要点的侧栏行名，逗号分隔或重复给；缺省读 <QA根>/侧栏点名.json")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    qa_root = os.path.abspath(args.qa_root)
    if not os.path.isdir(qa_root) or not qa_root.startswith(("/tmp/", "/private/tmp/")):
        raise SystemExit("QA 根必须是 /tmp/assetframe-qa.*，现在是 %s" % qa_root)
    if not os.path.exists(os.path.join(qa_root, APP_BINARY)):
        raise SystemExit("隔离根里没有 App：%s" % os.path.join(qa_root, APP_BINARY))
    build_helpers()
    scratch = os.path.join(qa_root, "measure")
    os.makedirs(scratch, exist_ok=True)

    only = [item.strip() for item in args.only.split(",") if item.strip()]
    only.append("校准")
    # 要点的行默认读标定文件（标定侧栏.py 写的），命令行可以覆盖。
    rows = []
    for item in args.folder:
        rows.extend(name.strip() for name in item.split(",") if name.strip())
    calibration = os.path.join(qa_root, "侧栏点名.json")
    if not rows and os.path.isfile(calibration):
        saved = json.load(open(calibration, encoding="utf-8"))
        rows = list(saved["rows"])
        log("侧栏点名来自标定文件（%s 标定）：%s" % (saved.get("calibrated_at"), rows))
    elif rows:
        log("侧栏点名来自命令行：%s" % rows)
    if "文件夹" in only and not rows:
        raise SystemExit("缺少文件夹点名：先跑 标定侧栏.py，或用 --folder 名称[,名称] 指定")

    report = {
        "measuredAt": datetime.datetime.now().isoformat(timespec="seconds"),
        "qaRoot": qa_root,
        "repeat": args.repeat,
        "environment": {
            "mac_model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
            "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
            "cores": subprocess.run(["sysctl", "-n", "hw.ncpu"], capture_output=True, text=True).stdout.strip(),
            "os": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
            "memory_gb": int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()) // 1024 // 1024 // 1024,
            "display": subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout,
        },
        "scroll_settings": {"seconds": args.scroll_seconds, "dy": args.scroll_dy, "interval": args.scroll_interval,
                            "capture_width": args.capture_width, "gallery_point": [args.gallery_fx, args.gallery_fy]},
        "scenarios": [],
    }

    if "校准" in only:
        try:
            report["probe_calibration"] = calibrate_probe(qa_root)
        except Exception as error:
            report["probe_calibration"] = {"error": str(error)}
        log("探针校准：%s" % json.dumps(report["probe_calibration"], ensure_ascii=False))

    if "首屏" in only:
        report["scenarios"].append(scenario_first_screen(qa_root, args.repeat))
    if "帧率" in only:
        report["scenarios"].append(scenario_scroll_fps(qa_root, args.repeat, args.scroll_seconds, args.scroll_dy,
                                                       args.scroll_interval, args.capture_width,
                                                       args.gallery_fx, args.gallery_fy))
    if "大图" in only or "筛选" in only:
        session = Session(qa_root).start()
        session.wait_settled(timeout=180)
        try:
            if "大图" in only:
                report["scenarios"].append(scenario_preview(qa_root, args.repeat, scratch))
            if "筛选" in only:
                report["scenarios"].append(scenario_search(qa_root, args.repeat, scratch))
        finally:
            session.stop()
    if "文件夹" in only:
        report["scenarios"].append(scenario_folder_switch(qa_root, args.repeat, rows, scratch))

    text = json.dumps(report, ensure_ascii=False, indent=1)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
        log("报告已写入 %s" % args.out)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
