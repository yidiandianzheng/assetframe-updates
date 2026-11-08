#!/usr/bin/env python3
"""用只读方式把「轻量挑图」四个时间桶在真实图库里的数量算出来。

规则与 Swift 侧 QuickPickScope 保持一致：只统计未删除的图片，桶边界取本地日历日零点，
近7天为「6 天前零点 → 今天结束」，口径「按文件生成时间」= sourceCreatedAt ?? sourceModifiedAt ?? createdAt，
「按入库时间」= createdAt；未挑过 = colorLabel 为空。

  python3 轻量挑图证据.py                 # 打印各桶数量
  python3 轻量挑图证据.py --json out.json # 同时落一份证据

以 mode=ro 打开 SQLite，只 select，不写库、不动素材。
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys

COCA_EPOCH_UNIX = 978307200  # 2001-01-01T00:00:00Z；payload 存的是 Cocoa 秒，桶边界是本地日历零点
BUCKETS = ("今天", "昨天", "前天", "近7天")
DAY_OFFSET = {"今天": 0, "昨天": 1, "前天": 2, "近7天": 6}


def date(value):
    # 必须换算成本地时间再比日历日，否则与 Swift 的 Calendar.current 差一个时区。
    return datetime.datetime.fromtimestamp(COCA_EPOCH_UNIX + value) if value is not None else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", default="/Volumes/SSD-1TB/Ai资产管理/香万家木兰.assetframelibrary")
    parser.add_argument("--json")
    parser.add_argument("--now", help="覆盖当前时间，ISO 格式，用于回放某一天的桶")
    args = parser.parse_args()

    db = os.path.join(os.path.abspath(args.library), "global-material-library.sqlite")
    connection = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    rows = connection.execute("select payload from materials").fetchall()
    quick_check = connection.execute("pragma quick_check").fetchone()[0]
    connection.close()

    now = datetime.datetime.fromisoformat(args.now) if args.now else datetime.datetime.now()
    start_of_today = datetime.datetime(now.year, now.month, now.day)

    images = []
    for (payload,) in rows:
        record = json.loads(payload)
        if record.get("kind") != "图片" or record.get("deletedAt") is not None:
            continue
        images.append(record)

    def upper(bucket):
        lower = start_of_today - datetime.timedelta(days=DAY_OFFSET[bucket])
        anchor = start_of_today if bucket == "近7天" else lower
        return anchor + datetime.timedelta(days=1)

    report = {
        "library": os.path.abspath(args.library),
        "quickCheck": quick_check,
        "now": now.isoformat(timespec="seconds"),
        "imageCount": len(images),
        "buckets": {},
    }
    for bucket in BUCKETS:
        hi = upper(bucket)
        lo = start_of_today - datetime.timedelta(days=DAY_OFFSET[bucket])
        entry = {}
        for basis_name, picker in (
            ("按文件生成时间", lambda r: date(r.get("sourceCreatedAt")) or date(r.get("sourceModifiedAt")) or date(r.get("createdAt"))),
            ("按入库时间", lambda r: date(r.get("createdAt"))),
        ):
            in_bucket = [r for r in images if (d := picker(r)) is not None and lo <= d < hi]
            unpicked = sum(1 for r in in_bucket if r.get("colorLabel") is None)
            entry[basis_name] = {
                "total": len(in_bucket),
                "unpicked": unpicked,
                "picked": len(in_bucket) - unpicked,
            }
        report["buckets"][bucket] = entry

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=1)
            handle.write("\n")

    print("图片总数 %d，quick_check=%s，now=%s" % (report["imageCount"], quick_check, report["now"]))
    for bucket in BUCKETS:
        for basis_name, counts in report["buckets"][bucket].items():
            print("%-4s %-14s 共 %4d 张，未挑 %4d，已挑 %4d"
                  % (bucket, basis_name, counts["total"], counts["unpicked"], counts["picked"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
