#!/usr/bin/env python3
"""「待确认」分类建议箱的隔离副本实跑验收（第 2 步）。

  python3 macos/perf/验收待确认箱.py --app <新构建的向量·素仓.app> \
      --qa-root /tmp/assetframe-qa.perf.XXXXXX --out /tmp/待确认箱验收 --repeat-note 首轮

只在隔离根里跑：ASSETFRAME_QA_DATA_ROOT 指向副本根，照片走符号链接镜像树，
生产库只做只读快照（测前/测后各一次，逐字节比对）。全程不联网、不调线上模型。

产出：
  <out>/报告.json            逐项验收结论与原始读数
  <out>/截图/宽度1100.png …  三档窗口宽度的箱界面截图
  <out>/截图/采纳前.png …    采纳前后对比
  <out>/按钮清单.json        AX 里实际能看到的按钮标签（证明点到的是真按钮）
  <out>/库状态*.json         直接读隔离副本 SQLite 的证据
"""
import argparse
import datetime
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

PERF_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(PERF_DIR))
CLI = os.path.join(REPO, "macos", "CLI", "assetframe")
DRIVER = os.path.join(PERF_DIR, "bin", "界面驱动")
EVIDENCE = os.path.join(PERF_DIR, "证据_生产库.py")
LIBRARY_NAME = "香万家木兰.assetframelibrary"
WIDTHS = (1100, 1440, 1920)


def now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def run(command, timeout=240, env=None):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env)
    return result


def driver(*words, timeout=180):
    if not os.path.exists(DRIVER):
        raise RuntimeError("缺少测量工具二进制：%s（先跑 测流畅度.py 让它自动编译）" % DRIVER)
    result = run([DRIVER] + [str(w) for w in words], timeout=timeout)
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip().startswith("{")]


def cli(qa_root, *words, timeout=30):
    command = [sys.executable, CLI] + list(words) + ["--endpoint", os.path.join(qa_root, "CLI", "endpoint.json"),
                                                    "--json", "--timeout", str(timeout)]
    result = run(command, timeout=timeout + 15)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError("CLI %s 无输出：%s" % (" ".join(words), (result.stderr or result.stdout)[-400:]))
    if not payload.get("ok"):
        raise RuntimeError("CLI %s 失败：%s" % (" ".join(words), payload.get("error")))
    return payload["result"]


def qa_pids(qa_root):
    """还开着的隔离实例 pid。

    实例是 Popen 用环境变量 ASSETFRAME_QA_DATA_ROOT 起的，ps 的 command 列里只有 App 自身路径，
    根本没有副本根——上一轮重启时旧实例因此一个都没被匹配到、也就没被关掉，它继续占着副本库的
    .writer.lock；新实例只能报「资源库已被其他会话占用」，库打不开，整轮实跑白等十几分钟。
    所以除了按命令行兜底，还要按「谁真的打开了副本根下的库文件/锁文件」来认（lsof）。
    """
    found = set()
    real_root = os.path.realpath(qa_root)
    markers = (qa_root.rstrip("/") + "/", real_root.rstrip("/") + "/")
    for line in run(["ps", "-Ao", "pid,command"]).stdout.splitlines():
        if any(marker in line for marker in markers) and ("AssetFrame" in line or "assetframe" in line):
            pid = int(line.split()[0])
            if pid != os.getpid():
                found.add(pid)
    watched = []
    cli_dir = os.path.join(qa_root, "CLI")
    if os.path.isdir(cli_dir):
        watched += [os.path.join(cli_dir, name) for name in os.listdir(cli_dir)
                    if name.startswith(("server.lock", "endpoint.json"))]
    watched += [os.path.join(qa_root, LIBRARY_NAME, name)
                for name in (".writer.lock", "global-material-library.sqlite")
                if os.path.exists(os.path.join(qa_root, LIBRARY_NAME, name))]
    for path in watched:
        holders = run(["lsof", "-t", path]).stdout.split()
        found.update(int(pid) for pid in holders if pid.isdigit() and int(pid) != os.getpid())
    return sorted(found)


def library_db(qa_root):
    return os.path.join(qa_root, LIBRARY_NAME, "global-material-library.sqlite")


def classification_values(record):
    """素材正式分类的维度字典。MaterialClassification 编码成扁平的 {维度: [标准词]}，
    但为防载荷口径变化，这里同时兼容 {"values": {...}} 的包装写法。"""
    raw = record.get("classification") or {}
    return raw.get("values") if isinstance(raw.get("values"), dict) else raw


def read_box(qa_root, label):
    """直接读隔离副本的库，取箱内建议与用户决定的原始行，作为界面读数的旁证。"""
    db = library_db(qa_root)
    connection = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        tables = {r[0] for r in connection.execute("select name from sqlite_master where type='table'")}
        suggestions = []
        if "tagging_suggestions" in tables:
            for (payload,) in connection.execute("select payload from tagging_suggestions"):
                value = json.loads(payload)
                ids = value.get("materialIDs") or []
                suggestions.append({"id": value["id"], "groupKey": value["groupKey"], "name": value["name"],
                                    "dimension": value["dimension"],
                                    "engine": value.get("engine"), "status": value.get("status"),
                                    "confidence": value.get("confidence"), "basis": value.get("basis"),
                                    "isNewTerm": value.get("isNewTerm"), "count": len(ids),
                                    "samples": len(ids[:4])})
        decisions = []
        if "tagging_decisions" in tables:
            for (payload,) in connection.execute("select payload from tagging_decisions"):
                value = json.loads(payload)
                decisions.append({"groupKey": value["groupKey"], "action": value["action"], "name": value["name"],
                                  "dimension": value.get("dimension"), "count": len(value.get("materialIDs") or [])})
        records = connection.execute("select count(*) from materials").fetchone()[0]
        quick_check = connection.execute("pragma quick_check").fetchone()[0]
        # 正式分类的填写情况：总数按维度分别统计，才能证明「采纳写的是哪一维」
        classified_records = 0
        dimension_counts = {}
        usage_placeholder = 0
        for (payload,) in connection.execute("select payload from materials"):
            values = classification_values(json.loads(payload))
            if values:
                classified_records += 1
            for dimension, terms in values.items():
                if terms:
                    dimension_counts[dimension] = dimension_counts.get(dimension, 0) + 1
            if values.get("usage") == ["设计素材"]:
                usage_placeholder += 1
    finally:
        connection.close()
    return {"label": label, "taken_at": now(), "tables": sorted(tables), "records": records,
            "quick_check": quick_check, "classified_records": classified_records,
            "dimension_counts": dimension_counts,
            "images_with_asset_type": dimension_counts.get("asset_type", 0),
            "usage_placeholder": usage_placeholder, "suggestion_rows": len(suggestions),
            "decision_rows": len(decisions), "pending": sum(1 for s in suggestions if s["status"] == "待确认"),
            "suggestions": suggestions, "decisions": decisions}


def screenshot(path, window_id):
    run(["screencapture", "-x", "-l", str(window_id), path], timeout=60)
    return os.path.exists(path) and os.path.getsize(path) > 10000


def screen_texts(pid, contains):
    """屏上静态文本读数（最多 8 条）：证明界面显示的是文字，而不只是颜色。"""
    rows = driver("texts", "--pid", pid, "--contains", contains)
    return [row["text"] for row in rows if row.get("text")][:8]


def ax_alive(pid, wait_seconds=90):
    """界面控件到底能不能被辅助功能读到——点按钮之前必须先确认这一条。

    2026-11-04 23:1x 两轮实跑扑空：窗口在窗口服务器里查得到（1440x900、标题正常），AX 却一个子元素
    都不给；同一时刻 NSWorkspace 报 frontmost 是 loginwindow、pmset 报 UserIsActive=0，用系统自己的
    System Events 查同一个进程也拿不到 window 1——所以不是驱动缺辅助功能权限，也不是 App 的按钮点不动，
    而是这台机器当下不给出界面树（锁屏/闲置）。没有这道门，脚本会把「环境读不到界面」一路记成
    「界面入口无法判定」，白跑十几分钟。
    """
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if len(driver("buttons", "--pid", pid) or []):
            return True
        time.sleep(2.0)
    return False


def ensure_library_open(qa_root, pid, report, stage, wait_seconds=120):
    """确认副本库真的开着；没开就用 CLI 打开。

    上一轮实测：重启后 CLI 已能连通，但界面还停在「打开资源库」窗口（8343 条记录加载需要时间），
    于是所有按钮点击都打在欢迎窗口上。这里先等记录数，等不到再主动打开。
    """
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        try:
            if (cli(qa_root, "status").get("store") or {}).get("recordCount"):
                return True
        except Exception:
            pass
        time.sleep(1.0)
    try:
        libs = cli(qa_root, "libraries")
        entries = libs if isinstance(libs, list) else []
        target = next((e for e in entries if str(e.get("path", "")).startswith(qa_root)), None)
        if not target:
            report["issues"].append("%s：等不到记录数，且 CLI libraries 里没有指向副本根的库" % stage)
            return False
        cli(qa_root, "open-library", target.get("id"))
        report["checks"]["CLI打开副本库(%s)" % stage] = target.get("id")
    except Exception as error:
        report["issues"].append("%s：CLI 打开副本库失败：%s" % (stage, str(error)[:200]))
        return False
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            if (cli(qa_root, "status").get("store") or {}).get("recordCount"):
                return True
        except Exception:
            pass
        time.sleep(1.5)
    report["issues"].append("%s：已发出打开指令但仍未读到记录数" % stage)
    return False


def capture_box_ui(pid, out, stage):
    """抓一次界面证据：AX 里真实可见的按钮 + 屏上卡片文字（五项信息以文字形式存在）。

    箱空时卡片不渲染，四项按钮自然读不到——判定要用「有卡片」，不能用「面板可达」。
    """
    buttons = driver("buttons", "--pid", pid)
    # 「拆分／合并」是 SwiftUI 的 Menu，在 AX 里不是 AXButton，要单独按 AXMenuButton 取一次。
    menus = driver("buttons", "--pid", pid, "--role", "AXMenuButton")
    labels = [row.get("label", "") for row in buttons] + [row.get("label", "") for row in menus]
    path = os.path.join(out, "按钮清单-%s.json" % stage.replace("／", "-").replace(" ", ""))
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"AXButton": buttons, "AXMenuButton": menus}, handle, ensure_ascii=False, indent=1)
    five = {
        "分类名与维度": screen_texts(pid, "类型："),
        "张数与依据": screen_texts(pid, "依据："),
        "把握": screen_texts(pid, "把握："),
        "新词标记": screen_texts(pid, "新词·待确认"),
    }
    return {"stage": stage, "按钮清单": path, "面板可达": any("扫描命名规则" in label for label in labels),
            "有卡片": bool(five["分类名与维度"] or five["张数与依据"]),
            "四项按钮": {key: any(label.startswith(key) for label in labels)
                        for key in ("采纳", "改名后采纳", "忽略", "拆分／合并")},
            "整批采纳": any(label.startswith("整批采纳") for label in labels),
            "五项": five}


def press(pid, text, report, stage, index=None, role=None):
    words = ["press", "--pid", pid, "--text", text]
    if index is not None:
        words += ["--index", index]
    if role is not None:
        words += ["--role", role]
    rows = driver(*words)
    outcome = rows[0] if rows else {"pressed": False}
    report["presses"].append({"stage": stage, "text": text, "index": index, "role": role, "outcome": outcome})
    if not outcome.get("pressed"):
        report["issues"].append("%s：点不到「%s」（AX 返回 %s）" % (stage, text, json.dumps(outcome, ensure_ascii=False)[:200]))
    return bool(outcome.get("pressed"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="新构建的 向量·素仓.app 路径")
    parser.add_argument("--qa-root", required=True, help="第 1 步建好的隔离副本根（/tmp/assetframe-qa.*）")
    parser.add_argument("--out", required=True, help="证据输出目录")
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--scan-timeout", type=int, default=900, help="相似图索引最长等待秒数")
    parser.add_argument("--skip-similarity", action="store_true",
                        help="跳过「扫描相似图」（箱里已有上一轮的产出时，只复看按钮与三档宽度截图）")
    parser.add_argument("--expect-version", default="V261023.10",
                        help="本轮构建的版本号前缀，用于确认验收跑的是刚构建的 App")
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

    report = {"started_at": now(), "qa_root": qa_root, "app": os.path.abspath(args.app),
              "widths": list(WIDTHS), "presses": [], "screenshots": [], "observations": [], "issues": [],
              "checks": {}}

    # 1) 测前：生产库只读快照
    pre = os.path.join(out, "生产库测前.json")
    run([sys.executable, EVIDENCE, "--out", pre], timeout=300)
    report["checks"]["生产库测前快照"] = os.path.exists(pre)

    box_before = read_box(qa_root, "启动前")
    report["box_before"] = box_before
    report["checks"]["启动前建议表是否已存在"] = "tagging_suggestions" in box_before["tables"]

    # 2) 启动隔离实例（安静模式：不 activate，只用 AX 设尺寸与点按钮）
    for pid in qa_pids(qa_root):
        run(["kill", "-TERM", str(pid)])
    # 等旧进程真的退出：上一轮导入探针就是栽在「kill 后 1 秒就起新实例」，
    # 旧进程还占着 CLI 的 endpoint/lock，新进程连不上，白等 150 秒。
    deadline = time.time() + 60
    while time.time() < deadline and qa_pids(qa_root):
        time.sleep(0.5)
    for stale in ("endpoint.json", "server.lock"):
        path = os.path.join(qa_root, "CLI", stale)
        if os.path.exists(path):
            # 只挪开、不删除：残留的是上一个实例的运行时文件，留档便于回看。
            os.replace(path, path + ".stale-" + datetime.datetime.now().strftime("%H%M%S"))
    log = open(os.path.join(out, "launch.log"), "a", encoding="utf-8")
    env = dict(os.environ, ASSETFRAME_QA_DATA_ROOT=qa_root)
    process = subprocess.Popen([binary], stdout=log, stderr=log, env=env)
    pid = process.pid
    report["pid"] = pid
    endpoint = os.path.join(qa_root, "CLI", "endpoint.json")
    deadline = time.time() + 150
    status = None
    while time.time() < deadline:
        if os.path.exists(endpoint):
            try:
                candidate = cli(qa_root, "status")
                if candidate.get("pid") == pid:
                    status = candidate
                    break
            except Exception:
                pass
        time.sleep(0.2)
    if status is None:
        report["issues"].append("App 起来了但 CLI 连不上，后续 UI 验收无法进行")
        finish(report, out, process, pre)
        return 1
    report["status"] = {"appVersion": status.get("appVersion"), "buildLabel": status.get("buildLabel"),
                        "recordCount": (status.get("store") or {}).get("recordCount"), "product": status.get("product")}
    report["checks"]["版本号是本轮构建"] = str(status.get("appVersion") or "").startswith(args.expect_version)
    report["checks"]["副本库已打开"] = ensure_library_open(qa_root, pid, report, "首轮启动")

    # 等预览管线排空，避免把加载中的画面当成基线
    deadline = time.time() + 150
    while time.time() < deadline:
        state = cli(qa_root, "status")
        pipeline = state.get("previewPipeline") or {}
        store = state.get("store") or {}
        if not state.get("busy") and not store.get("loading") and all(int(v) == 0 for v in pipeline.values()):
            break
        time.sleep(0.3)

    driver("unhide", "--pid", pid)
    driver("setframe", "--pid", pid, "--x", 0, "--y", 25, "--width", 1440, "--height", args.height)
    time.sleep(1.0)
    report["checks"]["界面辅助功能可用"] = ax_alive(pid)
    if not report["checks"]["界面辅助功能可用"]:
        report["issues"].append("读不到任何界面控件（本机锁屏或闲置时 WindowServer 不给界面树），"
                                "本轮界面项目不作判定，请在解锁状态下重跑")
        finish(report, out, process, pre)
        return 1

    # 3) 打开「标签与分类」→ 切到「待确认」页 → 分段默认停在「分类建议」
    if not press(pid, "标签与分类", report, "打开标签与分类"):
        finish(report, out, process, pre)
        return 1
    time.sleep(1.5)
    # 工作区默认停在「整理图片」页；「待确认」是分段选择器，AX 里常是 AXRadioButton。
    for role in ("AXRadioButton", "AXButton"):
        if press(pid, "待确认", report, "切到待确认页(%s)" % role, role=role):
            break
    time.sleep(1.5)
    baseline = capture_box_ui(pid, out, "箱面板刚打开")
    report["checks"]["箱面板已打开"] = baseline["面板可达"]
    report["observations"].append({"step": "打开时界面快照",
                                   "面板可达": baseline["面板可达"], "有卡片": baseline["有卡片"],
                                   "四项按钮": baseline["四项按钮"],
                                   "屏上卡片条数": len(baseline["五项"]["分类名与维度"])})

    window = biggest_window(pid)
    report["observations"].append({"step": "打开箱面板", "window": window, "box": compact(read_box(qa_root, "打开箱面板"))})

    # 4) 扫描命名规则（纯字符串，秒级）
    if press(pid, "扫描命名规则", report, "扫描命名规则"):
        deadline = time.time() + 180
        current = compact(read_box(qa_root, "规则扫描中"))
        stable = 0
        while time.time() < deadline:
            later = compact(read_box(qa_root, "规则扫描中"))
            stable = stable + 1 if (later["suggestion_rows"] == current["suggestion_rows"]
                                    and later["suggestion_rows"] > 0) else 0
            current = later
            if stable >= 2:
                break
            time.sleep(2.0)
        report["observations"].append({"step": "规则扫描后", "box": current})
        # 自动写入入口检查：规则扫描不得改写正式分类（按「有任何分类的素材数」与各维度计数双重对照）
        same = (box_before["classified_records"] == current["classified_records"]
                and box_before["dimension_counts"] == current["dimension_counts"])
        report["checks"]["规则扫描未改写正式分类"] = same
        report["observations"].append({"step": "正式分类计数对照", "启动前": {
                                           "classified_records": box_before["classified_records"],
                                           "images_with_asset_type": box_before["images_with_asset_type"]},
                                       "扫描后": {
                                           "classified_records": current["classified_records"],
                                           "images_with_asset_type": current["images_with_asset_type"]}})

    # 5) 扫描相似图（本机 Vision，逐张进度），中途抢一张带「已索引 x / y」的截图
    if args.skip_similarity:
        report["checks"]["相似图扫描"] = "本轮跳过（--skip-similarity，复用上一轮箱内产出）"
    elif press(pid, "扫描相似图", report, "扫描相似图"):
        progress_texts = []
        progress_shot = False
        deadline = time.time() + args.scan_timeout
        while time.time() < deadline:
            texts = screen_texts(pid, "已索引")
            progress_texts.extend(texts)
            if any(not text.endswith(" / 0") and "已索引 0 /" not in text for text in texts):
                shot = os.path.join(shots, "扫描相似图进度.png")
                report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                              "note": "相似图索引中，界面显示「已索引 x / y」", "texts": texts})
                progress_shot = True
                break
            time.sleep(2.0)
        if not progress_shot:
            report["issues"].append("未在界面采到「已索引 x / y」进度行（扫描过快或面板未显示），进度读数：%s"
                                    % (progress_texts[:4],))
        # 等索引结束：进度行消失即视为完成（texts 子命令末尾总会带一行统计，不能拿列表非空当判据）
        while time.time() < deadline:
            if not any(row.get("text") for row in driver("texts", "--pid", pid, "--contains", "已索引")):
                break
            time.sleep(3.0)
        after_visual = read_box(qa_root, "相似图扫描后")
        report["observations"].append({"step": "相似图扫描后", "box": compact(after_visual),
                                       "进度读数": progress_texts[:6]})
        engines = {}
        for row in after_visual["suggestions"]:
            engines[row["engine"]] = engines.get(row["engine"], 0) + 1
        report["checks"]["相似图与本机视觉有产出"] = engines
        report["checks"]["新词标记存在"] = any(row["isNewTerm"] for row in after_visual["suggestions"])
        report["checks"]["依据字段齐全"] = all(row["basis"] for row in after_visual["suggestions"])
        report["checks"]["把握为文字档位"] = sorted({row["confidence"] for row in after_visual["suggestions"]})

    # 5b) 箱里有卡片之后再取界面证据：四项按钮与五项信息必须对着"有内容"的箱测
    populated = capture_box_ui(pid, out, "扫描后箱内有建议")
    report["observations"].append({"step": "扫描后界面快照", "面板可达": populated["面板可达"],
                                   "有卡片": populated["有卡片"], "四项按钮": populated["四项按钮"],
                                   "整批采纳": populated["整批采纳"],
                                   "屏上卡片条数": len(populated["五项"]["分类名与维度"])})
    if populated["有卡片"]:
        report["checks"]["四个操作按钮齐全"] = populated["四项按钮"]
        report["checks"]["整批采纳按钮存在"] = populated["整批采纳"]
        report["checks"]["界面显示五项信息"] = {key: len(value) > 0 for key, value in populated["五项"].items()}
        report["界面文字样本"] = populated["五项"]
    else:
        verdict = "无法判定：箱面板不可达" if not populated["面板可达"] else "无法判定：扫描后箱里没有待确认卡片"
        report["checks"]["四个操作按钮齐全"] = verdict
        report["checks"]["界面显示五项信息"] = verdict
        report["issues"].append(verdict + "（四项按钮与五项信息需要有卡片的箱才能测，见 observations）")

    # 6) 三档窗口宽度截图
    for width in WIDTHS:
        driver("setframe", "--pid", pid, "--x", 0, "--y", 25, "--width", width, "--height", args.height)
        time.sleep(1.2)
        window = biggest_window(pid)
        path = os.path.join(shots, "宽度%s.png" % width)
        ok = screenshot(path, window["id"])
        report["screenshots"].append({"file": path, "requested_width": width, "actual": window, "captured": ok})

    # 7) 采纳一条 → 前后对比截图 + 正式分类写入证据（按被点亮那一组的维度对照）
    before_adopt = read_box(qa_root, "采纳前")
    shot = os.path.join(shots, "采纳前.png")
    report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                  "note": "箱内一条待确认建议的卡片"})
    adopted = press(pid, "采纳", report, "采纳一条")
    time.sleep(2.5)
    after_adopt = read_box(qa_root, "采纳后")
    shot = os.path.join(shots, "采纳后.png")
    report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                  "note": "采纳后：该组变已采纳，对应维度的正式分类计数增加"})
    flipped = flipped_groups(before_adopt, after_adopt, "已采纳")
    wrote = sum(1 for group in flipped
                if after_adopt["dimension_counts"].get(group["dimension"], 0)
                > before_adopt["dimension_counts"].get(group["dimension"], 0))
    report["observations"].append({"step": "采纳前后", "before": compact(before_adopt), "after": compact(after_adopt),
                                   "点亮并写入的组": flipped,
                                   "该维度计数": {g["dimension"]: [before_adopt["dimension_counts"].get(g["dimension"], 0),
                                                                    after_adopt["dimension_counts"].get(g["dimension"], 0)]
                                                  for g in flipped}})
    report["checks"]["采纳写入正式分类"] = bool(flipped) and wrote == len(flipped)
    report["checks"]["采纳记录用户决定"] = any(row["action"] in ("采纳", "改名后采纳") for row in after_adopt["decisions"])
    report["checks"]["采纳按钮可用"] = adopted

    # 8) 撤销一步 → 分类应回到采纳前
    undo = press(pid, "撤销", report, "撤销采纳")
    time.sleep(2.5)
    undone = read_box(qa_root, "撤销后")
    report["observations"].append({"step": "撤销后", "box": compact(undone)})
    report["checks"]["撤销回到采纳前的分类数"] = undone["classified_records"] == before_adopt["classified_records"] \
        and undone["dimension_counts"] == before_adopt["dimension_counts"]
    report["checks"]["撤销按钮可用"] = undo

    # 9) 改名后采纳：卡片按钮 → 弹层输入框赋值 → 确认。
    #    上一轮发现点「最后一个同名按钮」命中的是卡片按钮、不是弹层默认按钮（库里没有新名），
    #    因此先给弹层发回车（默认按钮是 Return 快捷键），不行再退回按钮方式，以库里的实际变化为准。
    renamed = None
    if press(pid, "改名后采纳", report, "打开改名弹层"):
        name = "自测改名-%s" % datetime.datetime.now().strftime("%H%M%S")
        filled = driver("settext", "--pid", pid, "--index", -1, "--value", name)
        report["presses"].append({"stage": "改名弹层赋值", "text": name, "outcome": filled[0] if filled else {}})
        time.sleep(0.6)
        before_rename = read_box(qa_root, "改名采纳前")
        flipped, confirm_way = [], None
        for how in ("回车", "按钮"):
            if how == "回车":
                rows = driver("key", "--pid", pid, "--code", "36")
                report["presses"].append({"stage": "改名弹层回车确认", "outcome": rows[0] if rows else {}})
            elif not press(pid, "改名后采纳", report, "确认改名后采纳(按钮)", index=-1):
                continue
            time.sleep(2.5)
            after_rename = read_box(qa_root, "改名采纳后")
            flipped = flipped_groups(before_rename, after_rename, "改名后采纳")
            if flipped:
                confirm_way = how
                break
        if flipped:
            hit = [g for g in flipped if g["name"] == name]
            wrote = sum(1 for g in hit
                        if after_rename["dimension_counts"].get(g["dimension"], 0)
                        > before_rename["dimension_counts"].get(g["dimension"], 0))
            report["observations"].append({"step": "改名后采纳", "新名": name, "确认方式": confirm_way,
                                           "点亮的组": flipped,
                                           "before": compact(before_rename), "after": compact(after_rename)})
            shot = os.path.join(shots, "改名后采纳.png")
            report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                          "note": "改名后采纳：卡片显示新分类名并已写入"})
            renamed = {"新名": name, "确认方式": confirm_way, "组数": len(flipped), "按新名命中": len(hit),
                        "写入维度数": wrote, "赋值回读": (filled[0].get("read_back") if filled else None)}
            press(pid, "撤销", report, "撤销改名采纳")
            time.sleep(2.0)
        else:
            report["observations"].append({"step": "改名后采纳", "新名": name, "点亮的组": [],
                                           "before": compact(before_rename), "after": compact(after_rename)})
            renamed = {"新名": name, "组数": 0, "赋值回读": (filled[0].get("read_back") if filled else None),
                       "结论": "未生效：回车与按钮两种方式都没让库里出现新名（界面与库都读到了，属于实测未通过）"}
    report["checks"]["改名后采纳"] = renamed if renamed is not None else "无法判定（弹层或输入框未驱动成功，见 presses）"

    # 10) 忽略一条 → 决定持久化
    if press(pid, "忽略", report, "忽略一条"):
        time.sleep(2.5)
        ignored = read_box(qa_root, "忽略后")
        report["observations"].append({"step": "忽略后", "box": compact(ignored)})
        report["checks"]["忽略记录决定"] = any(row["action"] == "忽略" for row in ignored["decisions"])

    # 11a) 拆分：卡片菜单里的「拆出一部分…」开弹层 → 勾一张图 + 填新名 → 拆出新建议。
    #      面板按「待确认优先 → 张数降序 → 名字升序」每页 12 组排列，所以先按同一口径
    #      算出目标组是第几张卡，再点那张卡的菜单。
    def pending_order(box_rows):
        return sorted((row for row in box_rows["suggestions"] if row["status"] == "待确认"),
                      key=lambda row: (-row["count"], row["name"]))

    def open_card_menu(index_of_card, item_text, stage):
        for role in ("AXMenuButton", "AXPopUpButton", "AXButton"):
            if press(pid, "拆分／合并", report, "%s：打开卡片菜单(第%d张,%s)" % (stage, index_of_card, role),
                     index=str(index_of_card), role=role):
                time.sleep(0.8)
                if press(pid, item_text, report, "%s：点菜单项(第%d张卡)" % (stage, index_of_card), role="AXMenuItem"):
                    return True
                driver("key", "--pid", str(pid), "--code", "53")  # Esc 收掉菜单，别挡住后面的动作
                time.sleep(0.5)
                return False
        return False

    split_outcome = {"done": False, "reason": "未能打开拆分弹层"}
    pre_split = read_box(qa_root, "拆分前")
    ordered = pending_order(pre_split)
    split_card = next((i for i, row in enumerate(ordered) if row["count"] >= 2), None)
    if split_card is not None and open_card_menu(split_card, "拆出一部分", "拆分"):
        time.sleep(1.0)
        shot = os.path.join(shots, "拆分弹层.png")
        report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                      "note": "拆分弹层：列出该组图片供勾选，并要求填拆出后的分类名"})
        split_name = "自测拆分-%s" % now().replace(":", "").replace("-", "")[2:]
        # 勾选行的标题是「文件名 + 绝对路径」，路径里一定含副本根，用它定位第一张。
        ticked = press(pid, qa_root, report, "勾选拆分弹层第一张", index="0", role="AXCheckBox")
        filled_split = driver("settext", "--pid", str(pid), "--value", split_name)
        confirmed = press(pid, "拆出新建议", report, "确认拆分")
        time.sleep(2.5)
        after_split = read_box(qa_root, "拆分后")
        target = ordered[split_card]
        # 卡片序号是按面板排序推算的，AX 遍历顺序不保证一致；箱里同张数的组好几个（9 张的就有两条），
        # 所以「哪一组真的少了一张」以整表前后差集为准，而不是信那张卡的映射。
        counts_before = {row["groupKey"]: row["count"] for row in pre_split["suggestions"]}
        dropped = {row["groupKey"]: counts_before[row["groupKey"]] - row["count"]
                   for row in after_split["suggestions"]
                   if row["groupKey"] in counts_before and row["count"] < counts_before[row["groupKey"]]}
        now_target = next((row for row in after_split["suggestions"] if row["groupKey"] == target["groupKey"]), {})
        new_row = next((row for row in after_split["suggestions"] if row["name"] == split_name), None)
        split_decision = next((row for row in after_split["decisions"] if row["action"] == "拆分"), None)
        report["observations"].append({"step": "拆分", "卡片序号": split_card, "目标组": target,
                                       "勾选": ticked, "赋值回读": (filled_split[0].get("read_back") if filled_split else None),
                                       "before": compact(pre_split), "after": compact(after_split),
                                       "新组": new_row, "原组剩余": now_target.get("count"),
                                       "真正减张数的组": dropped, "拆分决定": split_decision})
        if confirmed and new_row:
            split_outcome = {
                "done": True, "卡片序号": split_card, "新组名": split_name, "新组张数": new_row["count"],
                "原组张数变化": "%s → %s" % (target["count"], now_target.get("count")),
                "推算目标组少了一张": now_target.get("count") == target["count"] - new_row["count"],
                "箱内有组减张数": dropped,
                "减张数等于新组张数": sum(dropped.values()) == new_row["count"],
                # 库里记的是「拆完剩下的那批」，name 沿用原组名（供规则重跑时回放过滤），不是新名
                "记录拆分决定": split_decision is not None}
            shot = os.path.join(shots, "拆分后.png")
            report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                          "note": "拆分后：新组以待确认出现，原组张数减少"})
            press(pid, "撤销", report, "撤销拆分")
            time.sleep(2.0)
            undone_split = read_box(qa_root, "撤销拆分后")
            split_outcome["撤销后新组消失"] = not any(row["name"] == split_name for row in undone_split["suggestions"])
            # 撤销是否把整张箱恢复原样：逐组比对张数，比只看某一条更可靠
            diff = [row["groupKey"] for row in undone_split["suggestions"]
                    if row["groupKey"] in counts_before and row["count"] != counts_before[row["groupKey"]]]
            split_outcome["撤销后张数未恢复的组"] = diff
            split_outcome["撤销后箱与拆分前逐组一致"] = not diff and len(undone_split["suggestions"]) == len(pre_split["suggestions"])
        else:
            split_outcome = {"done": False,
                             "reason": "拆分未能写入（勾选=%s 赋值=%s 确认=%s，详见 presses）" % (ticked, filled_split, confirmed)}
    report["checks"]["拆分出新组并可撤销"] = split_outcome

    # 11b) 合并：同维度还有第二条待确认时，菜单里会出现「并到「…」」；点它应把来源组标为已合并。
    pre_merge = read_box(qa_root, "合并前")
    ordered = pending_order(pre_merge)
    dimensions = {}
    for position, row in enumerate(ordered):
        dimensions.setdefault(row["dimension"], []).append(position)
    merge_card = next((positions[1] for positions in dimensions.values() if len(positions) >= 2), None)
    merge_outcome = {"pressed": False, "reason": "同维度没有第二条待确认建议，或菜单未能用 AX 打开（见 presses）"}
    if merge_card is not None and open_card_menu(merge_card, "并到「", "合并"):
        time.sleep(2.5)
        merged = read_box(qa_root, "合并后")
        report["observations"].append({"step": "合并后", "box": compact(merged),
                                       "已合并条目": [row for row in merged["suggestions"] if row["status"] == "已合并"]})
        report["checks"]["合并记录决定"] = any(row["action"] == "合并" for row in merged["decisions"])
        shot = os.path.join(shots, "合并后.png")
        report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                      "note": "合并：来源组标记已合并并记一条决定"})
        merge_outcome = {"pressed": True, "卡片序号": merge_card, "决定数": merged["decision_rows"],
                         "已合并组数": sum(1 for row in merged["suggestions"] if row["status"] == "已合并")}
        press(pid, "撤销", report, "撤销合并")
        time.sleep(2.0)
    report["checks"]["拆分或合并"] = merge_outcome

    # 12) 整批采纳：一次把箱里待确认的组全写入正式分类，再整批撤销回来
    before_batch = read_box(qa_root, "整批采纳前")
    batch = None
    if press(pid, "整批采纳", report, "整批采纳"):
        deadline = time.time() + 120
        after_batch = read_box(qa_root, "整批采纳后")
        while time.time() < deadline and after_batch["pending"] == before_batch["pending"]:
            time.sleep(2.0)
            after_batch = read_box(qa_root, "整批采纳后")
        shot = os.path.join(shots, "整批采纳后.png")
        report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(pid)["id"]),
                                      "note": "整批采纳后：待确认组清零，正式分类计数增加"})
        batch = {"采纳前": compact(before_batch), "采纳后": compact(after_batch),
                 "点亮组数": len(flipped_groups(before_batch, after_batch, "已采纳")),
                 "决定行数": after_batch["decision_rows"]}
        press(pid, "撤销", report, "撤销整批采纳")
        time.sleep(3.0)
        undocked = read_box(qa_root, "整批撤销后")
        batch["撤销后"] = compact(undocked)
        batch["撤销回到整批前"] = (undocked["classified_records"] == before_batch["classified_records"]
                                and undocked["dimension_counts"] == before_batch["dimension_counts"]
                                and undocked["pending"] == before_batch["pending"])
        report["checks"]["整批采纳写入并可撤销"] = batch
    else:
        report["checks"]["整批采纳写入并可撤销"] = "无法判定：点不到「整批采纳」按钮"

    # 10) 退出重开：箱与决定应还在
    run(["kill", "-TERM", str(pid)])
    deadline = time.time() + 60
    while time.time() < deadline and process.poll() is None:
        time.sleep(0.5)
    persisted_path = os.path.join(out, "库状态退出后.json")
    with open(persisted_path, "w", encoding="utf-8") as handle:
        json.dump(read_box(qa_root, "退出后"), handle, ensure_ascii=False, indent=1)
    report["checks"]["退出后落盘证据"] = persisted_path

    restart = subprocess.Popen([binary], stdout=log, stderr=log, env=env)
    deadline = time.time() + 150
    reopened = None
    while time.time() < deadline:
        try:
            candidate = cli(qa_root, "status")
            if candidate.get("pid") == restart.pid:
                reopened = candidate
                break
        except Exception:
            pass
        time.sleep(0.5)
    if reopened:
        # 上一轮实测：新进程 CLI 已连通，但界面还停在「打开资源库」窗口，按钮全打在欢迎窗口上。
        library_opened = ensure_library_open(qa_root, restart.pid, report, "重开后")
        report["checks"]["重开后副本库已打开"] = library_opened
        driver("unhide", "--pid", restart.pid)
        press(restart.pid, "标签与分类", report, "重开后打开箱面板")
        time.sleep(1.5)
        for role in ("AXRadioButton", "AXButton"):
            if press(restart.pid, "待确认", report, "重开后切到待确认页(%s)" % role, role=role):
                break
        time.sleep(2.0)
        driver("setframe", "--pid", restart.pid, "--x", 0, "--y", 25, "--width", 1440, "--height", args.height)
        time.sleep(1.0)
        reopened_ui = capture_box_ui(restart.pid, os.path.dirname(shots) or ".", "重开后")
        shot = os.path.join(shots, "重开后仍在箱内.png")
        report["screenshots"].append({"file": shot, "captured": screenshot(shot, biggest_window(restart.pid)["id"]),
                                      "note": "重新启动后建议与决定仍在", "界面有卡片": reopened_ui["有卡片"],
                                      "屏上卡片条数": len(reopened_ui["五项"]["分类名与维度"])})
        state_after = read_box(qa_root, "重开后")
        report["checks"]["重开后决定仍在"] = state_after["decision_rows"] == json.load(open(persisted_path, encoding="utf-8"))["decision_rows"]
        report["checks"]["重开后界面仍能看到建议"] = reopened_ui["有卡片"]
        # 重跑扫描不应把已处理过的组变回待确认；必须真的点到「扫描命名规则」才下结论
        rerun_pressed = press(restart.pid, "扫描命名规则", report, "重开后重跑规则")
        deadline = time.time() + 60
        rerun = read_box(qa_root, "重跑后")
        baseline_rows = state_after["suggestion_rows"]
        while time.time() < deadline and rerun["suggestion_rows"] == baseline_rows:
            time.sleep(3.0)
            rerun = read_box(qa_root, "重跑后")
        report["observations"].append({"step": "重跑后", "box": compact(rerun), "决定数": state_after["decision_rows"],
                                       "扫描按钮已按下": rerun_pressed})
        if rerun_pressed:
            report["checks"]["重跑沿用既有决定"] = rerun["decision_rows"] >= state_after["decision_rows"]
            report["checks"]["重跑未重复提问已忽略组"] = not any(
                row["status"] == "待确认" and row["groupKey"] in {d["groupKey"] for d in rerun["decisions"] if d["action"] == "忽略"}
                for row in rerun["suggestions"])
        else:
            report["checks"]["重跑沿用既有决定"] = "无法判定：重开后未能点到「扫描命名规则」"
            report["checks"]["重跑未重复提问已忽略组"] = "无法判定：重开后未能点到「扫描命名规则」"
        run(["kill", "-TERM", str(restart.pid)])
        time.sleep(2.0)
    else:
        report["issues"].append("重启后 CLI 连不上，未验证持久化")

    log.close()
    finish(report, out, process, pre)
    return 0


def compact(box):
    return {k: box[k] for k in ("label", "taken_at", "records", "quick_check", "classified_records",
                                 "images_with_asset_type", "suggestion_rows", "decision_rows", "pending",
                                 "usage_placeholder", "dimension_counts")}


def flipped_groups(before, after, status):
    """两次读数之间状态变成 `status` 的组，用于确认界面点的是哪一条。"""
    previous = {row["id"]: row["status"] for row in before["suggestions"]}
    return [{"name": row["name"], "dimension": row["dimension"], "groupKey": row["groupKey"],
             "count": row["count"], "from": previous.get(row["id"], "新增")}
            for row in after["suggestions"] if row["status"] == status and previous.get(row["id"]) != status]


def biggest_window(pid):
    """取真正的主窗口：菜单栏条带（宽 2560、高 30）与通知条都混在同一 pid 里，只看宽度会抓错。"""
    rows = driver("windows", "--pid", pid, "--all")
    candidates = [row for row in rows if int(row.get("width", 0)) > 400 and int(row.get("height", 0)) > 300]
    if not candidates:
        return {"id": 0, "width": 0, "height": 0, "note": "没有 ≥400x300 的可见窗口"}
    named = [row for row in candidates if (row.get("name") or "").strip()]
    pool = named or candidates
    return max(pool, key=lambda row: float(row.get("width", 0)) * float(row.get("height", 0)))


def finish(report, out, process, pre):
    if process.poll() is None:
        run(["kill", "-TERM", str(process.pid)])
    post = os.path.join(out, "生产库测后.json")
    run([sys.executable, EVIDENCE, "--out", post], timeout=300)
    same = None
    try:
        before = json.load(open(pre, encoding="utf-8"))
        after = json.load(open(post, encoding="utf-8"))
        same = {key: before.get(key) == after.get(key) for key in ("recordCount", "quickCheck", "referencedPaths",
                                                                   "existingPaths", "missingPaths", "dbBytes",
                                                                   "dbSha256", "referencedPathListSha256",
                                                                   "libraryDirectoryFileCount")}
        report["checks"]["生产库测前测后一致"] = {"fields": same, "all_equal": all(same.values())}
    except Exception as error:  # 快照字段名变化时不要把整份报告丢掉
        report["issues"].append("生产库前后快照比对失败：%s" % error)
    report["finished_at"] = now()
    with open(os.path.join(out, "报告.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=1)
    print(json.dumps(report["checks"], ensure_ascii=False, indent=1))
    print("问题：%s" % ("；".join(report["issues"]) if report["issues"] else "无"))
    print("报告：%s" % os.path.join(out, "报告.json"))


if __name__ == "__main__":
    raise SystemExit(main())
