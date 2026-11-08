#!/usr/bin/env python3
"""新导入图片「逐张增量入箱」的隔离副本实跑验收（第 2 步补充证据）。

  python3 macos/perf/验收导入增量.py --app <新构建的向量·素仓.app> \
      --qa-root /tmp/assetframe-qa.perf.XXXXXX --out /tmp/导入增量验收

为什么单独一支脚本：任务书要求「新导入的图片逐张增量进箱、显示 已索引 x / y」，
而面板入口（NSOpenPanel）在安静模式里选不出路径（⌘⇧G 发给非激活进程不生效，实测「前往」文本命中 0），
按下「导入」后 runModal 还会占住主线程，所以喂图改用 App 自己的导入恢复记录：启动前把本次试验图片
写成 <库目录>/material-import-resume.json（**id 必须是合法 UUID**：App 用 `try?` 解码，字段不合法就静默当成「没有待恢复任务」）。
起实例后按环境选启动方式——辅助功能可用就点工作区底部的「待恢复的导入 …／继续此任务」，
锁屏读不到控件时改用 CLI `resume-import`。两条都是调同一个 `store.resumeImport()` → 同一条 `importFiles` 代码路径，
导入完成后由 App 自己清掉记录；区别只写进报告，不假装点过按钮。面板入口只作为可选的最后一步（--panel-evidence）。

只在隔离根里跑：试验图片写在副本根下的新目录里（每轮唯一后缀，不删任何文件），
生产库只做测前/测后只读快照并逐字节比对。全程不联网、不调线上模型。
点任何按钮前先确认辅助功能真的能读到界面控件（ax_alive），否则一律记「不作判定」并尽早收尾，
不空跑十几分钟轮询。

产出：
  <out>/报告.json                 逐项结论与原始读数
  <out>/截图/导入后面板.png …     关键界面证据
  <out>/库状态*.json              直接读副本 SQLite 的证据
"""
import importlib.util
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
import zlib

PERF_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(PERF_DIR))
DRIVER_SOURCE = os.path.join(PERF_DIR, "界面驱动.swift")
DRIVER = os.path.join(PERF_DIR, "bin", "界面驱动")

# 复用主验收脚本的读数与驱动函数，避免两套口径。
_spec = importlib.util.spec_from_file_location("box_acceptance", os.path.join(PERF_DIR, "验收待确认箱.py"))
box = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(box)

# 目录名与文件名都要能命中既有词表：GalleryAutoClassifier 的目录约定与 assetTypePriority。
SAMPLE_PLAN = [
    ("01_人物", ["人物角色_A01.png", "人物角色_A02.png"]),
    ("05_道具", ["道具_杯01.png", "道具_壶02.png", "道具_盘03.png"]),
    ("10_色卡", ["色卡_暖01.png", "色卡_冷02.png"]),
]


def make_png(path, rgb):
    """写一张 8x8 的纯色 PNG（只当素材用，不追求画面内容）。"""
    import struct
    width = height = 8
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        # 长度字段只算 data，CRC 覆盖 kind+data——写错过一次，sips 直接读不出尺寸。
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    payload = b"\x89PNG\r\n\x1a\n" + ihdr + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(payload)


def build_samples(qa_root, stamp, progress_images=0):
    """造两类素材：命中词表的小批（用于装箱与采纳），和不命中词表的一批（用于看进度是否逐张推进）。

    不命中的那批刻意用纯 ASCII 目录名和文件名：任何中文关键词都可能被命名规则命中，
    一旦命中就会把采纳步骤的撤销补丁撑大，也会让「规则命中本次新图」的口径变浑。
    """
    root = os.path.join(qa_root, "导入试验-%s" % stamp)
    colors = [(220, 60, 60), (60, 180, 90), (70, 110, 220)]
    made = []
    for index, (folder, names) in enumerate(SAMPLE_PLAN):
        target = os.path.join(root, folder)
        os.makedirs(target, exist_ok=True)
        for name in names:
            path = os.path.join(target, name)
            make_png(path, colors[index % len(colors)])
            made.append(path)
    if progress_images:
        target = os.path.join(root, "progress-batch")
        os.makedirs(target, exist_ok=True)
        for index in range(progress_images):
            path = os.path.join(target, "ziku%05d.png" % index)
            make_png(path, colors[index % len(colors)])
            made.append(path)
    return root, made


def launch_instance(box, binary, qa_root, out, report, stage, wait_seconds=200):
    """关掉同根残留实例 → 等它真的退出 → 把 CLI 运行时文件挪开 → 起新实例并等 CLI 认到新 pid。

    旧实例没退干净就起新的，新进程抢不到 CLI 服务端（endpoint/lock 还被占着），
    轮询只会一直读到旧 pid，看起来像「App 起来了但连不上」。上一轮的重启就是这样白等 150 秒。
    """
    leftovers = box.qa_pids(qa_root)
    for old in leftovers:
        subprocess.run(["kill", "-TERM", str(old)])
    deadline = time.time() + 60
    while time.time() < deadline and box.qa_pids(qa_root):
        time.sleep(0.5)
    cleared = not box.qa_pids(qa_root)
    for stale in ("endpoint.json", "server.lock"):
        path = os.path.join(qa_root, "CLI", stale)
        if os.path.exists(path):
            # 只挪开、不删除：留档便于回看
            os.replace(path, path + ".stale-" + time.strftime("%H%M%S"))
    log = open(os.path.join(out, "launch.log"), "a", encoding="utf-8")
    process = subprocess.Popen([binary], stdout=log, stderr=log,
                               env=dict(os.environ, ASSETFRAME_QA_DATA_ROOT=qa_root))
    pid = process.pid
    deadline = time.time() + wait_seconds
    status = None
    while time.time() < deadline:
        try:
            candidate = box.cli(qa_root, "status")
            if candidate.get("pid") == pid:
                status = candidate
                break
        except Exception:
            pass
        time.sleep(0.3)
    report.setdefault("启动记录", []).append({"阶段": stage, "pid": pid, "启动前残留实例": leftovers,
                                              "旧进程已退出": cleared, "CLI已连通": status is not None})
    return process, pid, status


def panel_windows(box, pid):
    """「导入」面板的窗口。非沙箱 App 的面板在自己进程里；被 AppKit 交给
    com.apple.appkit.xpc.openAndSavePanelService 承载时，窗口挂在别的 pid 上，
    只按 App 的 pid 查就会误判成「面板没弹」。两边都查，并按 id 去重。"""
    owners = [str(pid)] + subprocess.run(["pgrep", "-f", "openAndSavePanelService"],
                                         capture_output=True, text=True).stdout.split()
    rows, seen = [], set()
    for owner in owners:
        for win in (box.driver("windows", "--pid", owner, "--all") or []):
            if win.get("id") in seen:
                continue
            seen.add(win.get("id"))
            win = dict(win)
            win["owner"] = owner
            rows.append(win)
    return rows


def suggestions_poller(qa_root, interval=0.15):
    """高频采 CLI 的三只索引计数器。

    规则整趟只有几秒，每采一次 fork 一个 python 客户端的话一轮只采到三四条，读不出「逐张」；
    直接说 CLI 的 socket 协议（一条请求一次连接）才能几十条地采。凭据文件仍按 App 的规矩校验：0600、本机 127.0.0.1。
    """
    endpoint_path = os.path.join(qa_root, "CLI", "endpoint.json")
    rows, stop = [], threading.Event()

    def once(command, arguments=None, timeout=10):
        endpoint = json.load(open(endpoint_path, encoding="utf-8"))
        # 自己实现协议就自己守住 CLI 客户端的两条安全口径：凭据文件必须是本人所有的 0600 普通文件，只连本机。
        info = os.stat(endpoint_path)
        if stat.S_IMODE(info.st_mode) & 0o077 or info.st_uid != os.getuid():
            raise RuntimeError("连接信息文件权限不安全（须为当前用户的 0600）")
        if endpoint.get("host") != "127.0.0.1" or endpoint.get("protocolVersion") != 1:
            raise RuntimeError("只支持协议 1 的本机 127.0.0.1 端口")
        request = {"protocolVersion": 1, "id": str(uuid.uuid4()), "token": endpoint["token"],
                   "command": command, "arguments": arguments or {}}
        wire = json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n"
        with socket.create_connection((endpoint["host"], endpoint["port"]), timeout=timeout) as connection:
            connection.sendall(wire)
            received = bytearray()
            while b"\n" not in received:
                block = connection.recv(65536)
                if not block:
                    raise RuntimeError("服务连接结束但没有完整响应")
                received.extend(block)
        response = json.loads(bytes(received).split(b"\n", 1)[0])
        if response.get("id") != request["id"] or not response.get("ok"):
            raise RuntimeError("CLI %s 失败：%s" % (command, response.get("error")))
        return response["result"]

    def loop():
        started_at = time.time()
        while not stop.is_set():
            try:
                store = once("status").get("store") or {}
                rows.append({"t": round(time.time() - started_at, 2), "indexed": store.get("suggestionIndexed"),
                             "total": store.get("suggestionIndexTotal"), "running": store.get("suggestionIndexRunning"),
                             "importing": store.get("isImporting"), "phase": store.get("importPhase"),
                             "processed": store.get("importProcessed"), "added": store.get("importAdded"),
                             "loading": store.get("loading"), "persistenceError": store.get("persistenceError"),
                             "records": store.get("recordCount")})
            except Exception:
                pass
            time.sleep(interval)

    thread = threading.Thread(target=loop, daemon=True)
    thread.start()
    return {"rows": rows, "stop": stop.set, "call": once, "thread": thread}


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--qa-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--import-timeout", type=int, default=900, help="导入+增量入箱最长等待秒数")
    parser.add_argument("--settle-seconds", type=int, default=45,
                        help="记录数达标后再继续采计数器的秒数：增量索引在导入任务末尾，整库规则索引在元数据补齐后，两趟都要采到")
    parser.add_argument("--progress-images", type=int, default=1500,
                        help="额外导入的不命中词表的图片数，用于采到逐张进度读数（0＝不造）")
    parser.add_argument("--expect-version", default="V261023.11", help="本轮构建的版本号前缀")
    parser.add_argument("--panel-evidence", action="store_true",
                        help="最后再按一次「导入」采面板窗口证据（默认不做：NSOpenPanel 会占住主线程并把面板画到屏幕上，"
                             "负责人回到机器前不想被打扰就别开；入口本身已有一次人工诊断记录）")
    args = parser.parse_args()

    qa_root = os.path.abspath(args.qa_root)
    if not qa_root.startswith("/tmp/assetframe-qa."):
        raise SystemExit("拒绝使用非隔离根：%s（必须是 /tmp/assetframe-qa.*）" % qa_root)
    out = os.path.abspath(args.out)
    shots = os.path.join(out, "截图")
    os.makedirs(shots, exist_ok=True)
    binary = os.path.join(os.path.abspath(args.app), "Contents", "MacOS", "AssetFrame")
    if not os.path.exists(binary):
        raise SystemExit("找不到可执行文件：%s" % binary)
    if not os.path.exists(DRIVER) or os.path.getmtime(DRIVER) < os.path.getmtime(DRIVER_SOURCE):
        os.makedirs(os.path.dirname(DRIVER), exist_ok=True)
        result = subprocess.run(["xcrun", "swiftc", "-O", DRIVER_SOURCE, "-o", DRIVER],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit("编译界面驱动失败：%s" % result.stderr[-1500:])
    box.DRIVER = DRIVER

    stamp = box.now().replace(":", "").replace("-", "")[2:]
    report = {"started_at": box.now(), "qa_root": qa_root, "app": os.path.abspath(args.app),
              "presses": [], "screenshots": [], "observations": [], "issues": [], "checks": {}}

    pre = os.path.join(out, "生产库测前.json")
    subprocess.run([sys.executable, box.EVIDENCE, "--out", pre], timeout=300)
    report["checks"]["生产库测前快照"] = os.path.exists(pre)

    sample_root, sample_files = build_samples(qa_root, stamp, args.progress_images)
    report["试验目录"] = sample_root
    report["试验图片数"] = len(sample_files)
    report["试验图片"] = [os.path.relpath(p, qa_root) for p in sample_files[:20]]

    before = box.read_box(qa_root, "导入前")
    ids_before = record_ids(qa_root)
    report["checks"]["导入前建议表存在"] = "tagging_suggestions" in before["tables"]

    # 喂图走工作区底部的「待恢复的导入 · …／继续此任务」：同一条 importFiles 代码路径，
    # 导入完成后由 App 自己清掉恢复记录。恢复记录必须在启动前写好——库打开时 App 就把它读进
    # store.resumableImport（2026-11-04 实测：先写记录再起实例，一次到位），
    # 不必「先起实例、写记录、再重启」；重启那一版还踩了残留实例占着副本库写锁的坑。
    # 为什么不用面板选路径：安静模式里 ⌘⇧G 发给非激活进程打不开「前往文件夹」（实测 texts 命中 0），
    # 而面板的 runModal 会占住主线程，之后的 AX 点击全都落空——所以面板留到最后再证明。
    resume_path = os.path.join(qa_root, box.LIBRARY_NAME, "material-import-resume.json")
    with open(resume_path, "w", encoding="utf-8") as handle:
        json.dump({"id": str(uuid.uuid4()).upper(), "paths": sample_files, "projectID": None,
                   "localFolder": None, "audioOnly": False,
                   # Swift 的 Date 默认按 2001-01-01 参考时间编解码，写 Unix 秒会差 28 年
                   "createdAt": time.time() - 978307200.0}, handle, ensure_ascii=False)
    report["恢复记录文件"] = resume_path

    process, pid, status = launch_instance(box, binary, qa_root, out, report, "带恢复记录启动")
    report["pid"] = pid
    if status is None:
        report["issues"].append("App 起来了但 CLI 连不上，导入验收无法进行")
        box.finish(report, out, process, pre)
        return 1
    report["status"] = {"appVersion": status.get("appVersion"), "buildLabel": status.get("buildLabel")}
    report["checks"]["版本号是本轮构建"] = str(status.get("appVersion") or "").startswith(args.expect_version)
    report["checks"]["副本库已打开"] = box.ensure_library_open(qa_root, pid, report, "导入试验启动")
    if not report["checks"]["副本库已打开"]:
        report["issues"].append("副本库没打开（常见原因是残留实例占着副本库写锁），导入增量本轮不作判定")
        box.finish(report, out, process, pre)
        return 1
    # 界面可用性只是「能不能采界面证据」，不是整轮的门槛：本机锁屏/闲置时 WindowServer 不给界面树，
    # 这时改用 CLI resume-import 起同一份 store.resumeImport()，数据类项目照样能判。
    box.driver("unhide", "--pid", pid)
    box.driver("setframe", "--pid", pid, "--x", 0, "--y", 25, "--width", 1440, "--height", args.height)
    time.sleep(1.0)
    report["checks"]["界面辅助功能可用"] = box.ax_alive(pid, wait_seconds=20)

    records_before = before["records"]

    status = box.cli(qa_root, "status")
    report["checks"]["恢复记录已被读到"] = bool((status.get("store") or {}).get("resumableImport"))
    if not report["checks"]["恢复记录已被读到"]:
        # App 解码恢复记录用的是 try?：字段不合法（id 不是合法 UUID 最常见）就静默当成「没有待恢复任务」。
        report["issues"].append("副本库没读到导入恢复记录（id 必须是合法 UUID，App 对不合法字段是静默丢弃），导入增量不作判定")
        box.finish(report, out, process, pre)
        return 1

    poller = suggestions_poller(qa_root)
    started, start_route = False, None
    if report["checks"]["界面辅助功能可用"]:
        # 先点「继续此任务」把导入真正起起来，再开箱面板：「已索引 x / y」只画在待确认面板里
        # （ClassificationSuggestionPanel），而复制阶段就有几分钟，面板开着才采得到逐张读数。
        started = box.press(pid, "继续此任务", report, "点继续此任务")
        start_route = "界面按钮「继续此任务」" if started else None
    if not started:
        # 锁屏时点不到按钮：CLI 的 import.resume 走的是同一个 store.resumeImport() → importFiles，
        # 但它是 CLI 入口，不能算「界面按钮实测通过」，所以启动方式单独记一项。
        try:
            started = bool(box.cli(qa_root, "resume-import", timeout=30).get("started"))
            start_route = "CLI import.resume（与按钮同一个 store.resumeImport()）" if started else None
        except Exception as error:
            report["issues"].append("CLI resume-import 没把导入起起来：%s" % error)
    report["checks"]["导入已启动"] = started
    report["checks"]["导入启动方式"] = start_route or "未启动"
    if not started:
        report["issues"].append("恢复记录读到了但导入没起起来，后续增量与入箱不作判定")
        poller["stop"]()
        box.finish(report, out, process, pre)
        return 1
    if report["checks"]["界面辅助功能可用"]:
        box.press(pid, "标签与分类", report, "打开标签与分类")
        time.sleep(1.5)
        for role in ("AXRadioButton", "AXButton"):
            if box.press(pid, "待确认", report, "切到待确认页(%s)" % role, role=role):
                break
        time.sleep(1.0)

    # 等导入与增量索引走完。等待条件只看高频采器的读数：原来每轮再 fork 一次 CLI 客户端，
    # 一次采样要 2～3 秒，而导入末尾那一趟规则只要一秒多，中间值全被采漏（2026-11-04 23:44 轮实测 28 条读数、indexed 始终 0）。
    # 记录数上来了还不算完：indexImportedImages 在 importTask 的 defer(isImporting=false) 之前跑，
    # 之后 supplementMetadata 补齐像素尺寸还会触发一次整库规则索引，所以再等 settle_seconds 让两趟都采到。
    deadline = time.time() + args.import_timeout
    progress_texts, progress_shot, after_import, ui_seen = [], False, None, 0.0
    target_records = records_before + len(sample_files)
    idle_since = None
    while time.time() < deadline:
        rows = poller["rows"]
        last = rows[-1] if rows else {}
        if (report["checks"]["界面辅助功能可用"] and time.time() - ui_seen >= 5.0
                and not progress_shot):
            # 界面文字采样要起子进程，会拖慢高频采器，所以只在辅助功能可用时低频做，采到一次就停
            ui_seen = time.time()
            texts = box.screen_texts(pid, "已索引")
            progress_texts.extend(texts)
            if texts and any(not t.endswith(" / 0") and "已索引 0 /" not in t for t in texts):
                path = os.path.join(shots, "导入进度.png")
                report["screenshots"].append({"file": path, "captured": box.screenshot(path, box.biggest_window(pid)["id"]),
                                              "note": "导入后逐张增量索引，界面显示「已索引 x / y」", "texts": texts})
                progress_shot = True
        if (last.get("records") or 0) >= target_records and not last.get("importing"):
            if idle_since is None:
                idle_since = time.time()
            elif time.time() - idle_since >= args.settle_seconds and not last.get("running"):
                break
        else:
            idle_since = None
        time.sleep(0.2)
    after_import = box.read_box(qa_root, "导入后")
    poller["stop"]()
    index_readings = poller["rows"]
    with open(os.path.join(out, "计数器读数.json"), "w", encoding="utf-8") as handle:
        json.dump(index_readings, handle, ensure_ascii=False)

    stepped = [row for row in index_readings if (row["indexed"] or 0) > 0]
    # 计数变化步数：同一趟里 indexed 至少出现过两个不同值，才叫「逐张推进」而不是「一次写全」
    steps = []
    for row in stepped:
        if not steps or (steps[-1][1], steps[-1][2]) != (row["indexed"], row["total"]):
            steps.append((row["t"], row["indexed"], row["total"], row["running"]))
    incremental = [row for row in index_readings if (row["total"] or 0) == len(sample_files) and (row["indexed"] or 0) > 0]
    report["observations"].append({"step": "导入前后", "before": box.compact(before), "after": box.compact(after_import),
                                   "进度读数": progress_texts[:10], "计数变化序列": steps[:20],
                                   "高频读数条数": len(index_readings),
                                   "阶段序列": list(dict.fromkeys(row.get("phase") for row in index_readings if row.get("phase"))),
                                   "处理数变化": [row.get("processed") for row in index_readings[::max(1, len(index_readings) // 12)]]})
    new_records = after_import["records"] - records_before
    report["checks"]["导入新增记录数"] = new_records
    report["checks"]["界面出现逐张进度"] = ("实测到" if progress_shot else
                                        ("不作判定：本机读不到界面控件树" if not report["checks"]["界面辅助功能可用"] else "界面未采到「已索引」文字"))
    report["checks"]["CLI看到索引在推进"] = {"读数条数": len(index_readings), "indexed>0条数": len(stepped),
                                            "计数变化步数": len(steps),
                                            "最大indexed": max([r["indexed"] or 0 for r in index_readings] or [0]),
                                            "样例": steps[:8],
                                            "结论": "实测到逐张推进" if len(steps) >= 2 else "未能实机采到中间值"}
    report["checks"]["增量只算本次导入的图"] = {
        "本次导入图片数": len(sample_files),
        "总数等于本次导入数的读数": incremental[:6],
        "见过的最大total": max([r["total"] or 0 for r in index_readings] or [0]),
        "结论": "实测到" if incremental else "未能实机采到（规则整趟过快，轮询错过）；逐张上报本身由自测断言覆盖"}

    # 新导入的图片：正式分类必须还是空的（自动结果只进箱）
    fresh_ids = sorted(record_ids(qa_root) - ids_before)
    rows = suggestions_with_ids(qa_root)
    written = [row for row in rows if row["engine"] == "规则"]
    report["checks"]["规则引擎有进箱"] = [{"name": row["name"], "count": row["count"], "basis": row["basis"],
                                          "confidence": row["confidence"], "isNewTerm": row["isNewTerm"],
                                          "命中本次新图": len(set(row["materialIDs"]) & set(fresh_ids))}
                                         for row in written]
    with_type = _count_with_asset_type(qa_root, fresh_ids)
    report["checks"]["新图正式分类仍为空"] = {"新记录数": len(fresh_ids), "已带asset_type的新记录": with_type,
                                              "结论": "未被自动写入" if with_type == 0 else "有 %d 张被自动写入，违反只进箱" % with_type}
    # 「增量而不是全库重跑」的库侧对照：这些规则组的成员应当全部落在本次新导入的 id 里
    wholly_new = [row for row in written if set(row["materialIDs"]) <= set(fresh_ids)]
    report["checks"]["规则组只引用本次新图"] = {"引用到新图的规则组": len([row for row in written if set(row["materialIDs"]) & set(fresh_ids)]),
                                             "成员全是新图的规则组": [{"name": row["name"], "engine": row["engine"], "count": row["count"]}
                                                                 for row in wholly_new]}

    if report["checks"]["界面辅助功能可用"]:
        shot = os.path.join(shots, "导入后面板.png")
        report["screenshots"].append({"file": shot, "captured": box.screenshot(shot, box.biggest_window(pid)["id"]),
                                      "note": "导入后箱内出现规则引擎的组"})

    # 采纳其中一条规则建议 → 正式分类写入 → 撤销回来。
    # 面板按「待确认优先 → 张数降序 → 名字升序」每页 12 组排列，所以先按同一口径
    # 算出目标组落在第几页第几张，翻页后点那一张的「采纳」，点完回库确认翻的确实是它。
    page_size = 12
    pending = sorted((row for row in rows if row["status"] == "待确认"), key=lambda row: (-row["count"], row["name"]))
    candidates = [row for row in pending if row["engine"] == "规则" and set(row["materialIDs"]) & set(fresh_ids)]
    rule_group = candidates[0] if candidates else None
    if not report["checks"]["界面辅助功能可用"]:
        # 箱里没有 CLI 采纳命令，采纳/撤销只能按按钮；界面不可用就明确记「不作判定」，不拿自测冒充实机。
        report["checks"]["采纳规则建议写入正式分类"] = ("不作判定：本轮界面不可用（导入由 CLI 起，"
                                                     "候选组「%s」%d 张已实测到，采纳按钮待解锁重跑）"
                                                     % ((rule_group or {}).get("name", "未选出"), (rule_group or {}).get("count", 0))
                                                     if rule_group else "无法判定：箱里没有引用本次新图的规则组")
        report["checks"]["撤销回到导入后状态"] = "不作判定：同上"
    elif rule_group:
        position = next(i for i, row in enumerate(pending) if row["groupKey"] == rule_group["groupKey"])
        for step in range(position // page_size):
            box.press(pid, "下一页", report, "翻到目标组所在页(%d)" % (step + 2))
            time.sleep(0.8)
        picked = box.press(pid, "采纳", report, "采纳一条规则建议", index=str(position % page_size))
        time.sleep(2.5)
        adopted = box.read_box(qa_root, "采纳规则后")
        rows_after = {row["groupKey"]: row for row in suggestions_with_ids(qa_root)}
        target_after = rows_after.get(rule_group["groupKey"]) or {}
        wrote = _count_with_asset_type(qa_root, rule_group["materialIDs"])
        report["checks"]["采纳规则建议写入正式分类"] = {
            "按钮按下": picked, "组名": rule_group["name"], "组键": rule_group["groupKey"],
            "面板位置": {"待确认序号": position, "页": position // page_size + 1, "第几张": position % page_size + 1},
            "点到的就是目标组": target_after.get("status") in ("已采纳", "改名后采纳"),
            "回读状态": target_after.get("status"),
            "涉及张数": rule_group["count"], "已写入": wrote,
            "正式分类总数变化": adopted["images_with_asset_type"] - after_import["images_with_asset_type"]}
        box.press(pid, "撤销", report, "撤销采纳规则建议")
        time.sleep(2.5)
        undone = box.read_box(qa_root, "撤销后")
        report["checks"]["撤销回到导入后状态"] = {"分类总数回到": undone["images_with_asset_type"] == after_import["images_with_asset_type"],
                                                  "新图仍写入数": _count_with_asset_type(qa_root, rule_group["materialIDs"])}
    else:
        report["checks"]["采纳规则建议写入正式分类"] = "无法判定：箱里没有引用本次新图的规则组"

    # 界面「导入」入口放到最后证明，而且默认不做（--panel-evidence 才开）：NSOpenPanel 的 runModal
    # 会占住主线程并按完之后这个实例的 AX 树就可能读不到控件，所以所有点击类检查做完才按它。
    # 判定不看 AXPress 返回值（必然回 -25204，控件本身 enabled），只看「导入素材或文件夹」窗口出没出现。
    if args.panel_evidence:
        modal_probe = (box.driver("press", "--pid", str(pid), "--text", "导入") or [{}])[0]
        report["presses"].append({"stage": "点导入(AXButton，预期 runModal 让 AXPress 超时)", "text": "导入",
                                  "index": None, "role": None, "outcome": modal_probe})
        time.sleep(2.5)
        visible_windows = panel_windows(box, pid)
        panel = next((w for w in visible_windows if "导入素材或文件夹" in str(w.get("name") or "")), None)
        panel_shot = os.path.join(shots, "导入面板.png")
        report["screenshots"].append({"file": panel_shot,
                                      "captured": bool(panel) and box.screenshot(panel_shot, panel["id"]),
                                      "note": "点「导入」后弹出的选择面板（窗口名「导入素材或文件夹」）"})
        report["checks"]["导入入口"] = {
            "面板窗口": (panel or {}).get("name"),
            "面板窗口归属": (panel or {}).get("owner"),
            "面板尺寸": "%sx%s" % ((panel or {}).get("width"), (panel or {}).get("height")),
            "当次可见窗口": [{"owner": w.get("owner"), "name": w.get("name"),
                             "size": "%sx%s" % (w.get("width"), w.get("height"))} for w in visible_windows][:8],
            "判定": "可点：面板窗口出现" if panel else "无法判定：面板窗口未出现",
        }
        if panel is None:
            report["issues"].append("点「导入」后没有采到「导入素材或文件夹」面板窗口，界面导入入口无法确认")
        else:
            box.press(pid, "取消", report, "关掉导入面板")
    else:
        report["checks"]["导入入口"] = "本轮未采（默认不开 --panel-evidence：面板 runModal 会占住主线程并把面板画到屏幕上）"

    subprocess.run(["kill", "-TERM", str(pid)])
    deadline = time.time() + 60
    while time.time() < deadline and process.poll() is None:
        time.sleep(0.5)
    with open(os.path.join(out, "库状态退出后.json"), "w", encoding="utf-8") as handle:
        json.dump(box.read_box(qa_root, "退出后"), handle, ensure_ascii=False, indent=1)
    report["checks"]["试验目录留在副本根"] = sample_root
    box.finish(report, out, process, pre)
    return 0


def suggestions_with_ids(qa_root):
    """箱内建议行 + 它们引用的素材 id（read_box 只给张数，采纳对照需要 id）。"""
    import sqlite3
    connection = sqlite3.connect("file:%s?mode=ro" % box.library_db(qa_root), uri=True)
    try:
        if not connection.execute("select count(*) from sqlite_master where type='table' and name='tagging_suggestions'").fetchone()[0]:
            return []
        rows = []
        for (payload,) in connection.execute("select payload from tagging_suggestions"):
            value = json.loads(payload)
            rows.append({"id": value["id"], "groupKey": value["groupKey"], "name": value["name"],
                         "dimension": value["dimension"], "engine": value.get("engine"),
                         "status": value.get("status"), "confidence": value.get("confidence"),
                         "basis": value.get("basis") or [], "isNewTerm": bool(value.get("isNewTerm")),
                         "count": len(value.get("materialIDs") or []), "materialIDs": value.get("materialIDs") or []})
        return rows
    finally:
        connection.close()


def record_ids(qa_root):
    """副本库里当前的素材 id 集合（用于算导入的增量）。"""
    import sqlite3
    connection = sqlite3.connect("file:%s?mode=ro" % box.library_db(qa_root), uri=True)
    try:
        return {json.loads(payload)["id"] for (payload,) in connection.execute("select payload from materials")}
    finally:
        connection.close()


def _count_with_asset_type(qa_root, wanted):
    import sqlite3
    db = box.library_db(qa_root)
    connection = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        hits = 0
        for (payload,) in connection.execute("select payload from materials"):
            record = json.loads(payload)
            if record["id"] not in wanted:
                continue
            if (record.get("classification") or {}).get("asset_type"):
                hits += 1
        return hits
    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main())
