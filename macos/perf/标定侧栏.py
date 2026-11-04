#!/usr/bin/env python3
"""标定侧栏：把隔离实例窗口固定到统一尺寸，截图并列出可点的文件夹行。

用法：
  python3 标定侧栏.py --qa-root /tmp/assetframe-qa.xxxx --capture 基线/侧栏标定.png

产出 <QA根>/侧栏点名.json（文件夹行的可访问标签），测流畅度.py 跑「文件夹」场景时读它，
用 AXPress 按名字点行，不依赖屏幕坐标、也不需要把窗口提到最前。
"""
import argparse
import datetime
import importlib.util
import json
import os
import subprocess
import sys

PERF_DIR = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ce_liang", os.path.join(PERF_DIR, "测流畅度.py"))
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qa-root", required=True)
    parser.add_argument("--capture", default="")
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--pick", action="append", default=[], dest="picks",
                        help="要保留的文件夹行名（可重复）；缺省收下所有带路径的文件夹行")
    args = parser.parse_args()

    qa_root = os.path.abspath(args.qa_root)
    measure.build_helpers()
    measure.reset_browse(qa_root)

    session = measure.Session(qa_root).start()
    try:
        session.prepare_background(args.width, args.height)
        _, state = session.wait_settled(timeout=180)
        windows = [w for w in measure.driver("windows", "--pid", session.pid) if w.get("width", 0) > 800]
        if not windows:
            raise RuntimeError("找不到主窗口")
        window = windows[0]
        if args.capture:
            subprocess.run(["screencapture", "-x", "-o", "-l", str(int(window["id"])), args.capture], check=True)

        # 文件夹行的标签形如「名称、数量|/绝对路径\n素材数量包含子文件夹…」，其余按钮没有这段帮助文本。
        labels = [item["label"] for item in measure.driver("buttons", "--pid", session.pid)]
        rows = {}
        for label in labels:
            head, _, help_text = label.partition("|")
            if "、" not in head or "素材数量包含子文件夹" not in help_text:
                continue
            rows[head.split("、")[0]] = head
        # 范围行（全部素材/未分类…）没有数量后缀和帮助文本，标签就是名字本身。
        for name in ("全部素材", "未分类", "未标签", "最近使用", "通用资产", "导出", "失联素材", "回收站"):
            if name in [entry.partition("|")[0] for entry in labels]:
                rows.setdefault(name, name)
        if args.picks:
            missing = [name for name in args.picks if name not in rows]
            if missing:
                raise RuntimeError("侧栏里没有这些行：%s（可点行：%s）" % (missing, sorted(rows)))
            rows = {name: rows[name] for name in args.picks}

        record = {
            "calibrated_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "window": {k: window[k] for k in ("id", "x", "y", "width", "height")},
            "backing_scale": measure.driver("display")[0].get("scale"),
            "visible_count": (state.get("workspace") or {}).get("visibleCount"),
            "rows": rows,
            "note": "行名用于 AXPress，不用屏幕坐标；「、数量」是侧栏标签的一部分，帮助文本里的路径用来区分文件夹行和其他按钮",
        }
        print(json.dumps(record, ensure_ascii=False, indent=1))
        with open(os.path.join(qa_root, "侧栏点名.json"), "w", encoding="utf-8") as handle:
            json.dump(record, handle, ensure_ascii=False, indent=1)
            handle.write("\n")
    finally:
        session.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
