#!/usr/bin/env python3
"""记录生产图库的只读快照，用来证明测量前后原库没被动过。

  python3 证据_生产库.py --out 交接记录/素仓优化_2026-11-04/证据_生产库测后.json

以 mode=ro 打开 SQLite，只读 pragma 与 select，不写任何文件；库目录只 stat 不打开内容。
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
import sqlite3
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", default="/Volumes/SSD-1TB/Ai资产管理/香万家木兰.assetframelibrary")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    library = os.path.abspath(args.library)
    db = os.path.join(library, "global-material-library.sqlite")
    connection = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    rows = connection.execute("select payload from materials").fetchall()
    records = [json.loads(payload) for (payload,) in rows]
    referenced = set()
    kinds = collections.Counter()
    for record in records:
        kinds[record.get("kind") or "其他"] += 1
        for key in ("sourcePath", "sourceURL"):
            value = record.get(key)
            if isinstance(value, str) and value.startswith("/"):
                referenced.add(value)
        for value in record.get("sourceLocations") or []:
            if isinstance(value, str) and value.startswith("/"):
                referenced.add(value)
    quick_check = connection.execute("pragma quick_check").fetchone()[0]
    connection.close()

    existing = sum(1 for path in sorted(referenced) if os.path.exists(path))
    library_files = sorted(name for name in os.listdir(library) if not name.startswith("."))
    digest = hashlib.sha256(open(db, "rb").read()).hexdigest()
    path_digest = hashlib.sha256(("\n".join(sorted(referenced)) + "\n").encode("utf-8")).hexdigest()

    snapshot = {
        "recordedAt": datetime.datetime.now().isoformat(timespec="seconds"),
        "library": library,
        "recordCount": len(records),
        "quickCheck": quick_check,
        "referencedPaths": len(referenced),
        "existingPaths": existing,
        "missingPaths": len(referenced) - existing,
        "dbBytes": os.path.getsize(db),
        "dbSha256": digest,
        "referencedPathListSha256": path_digest,
        "kindCounts": {key: kinds[key] for key in sorted(kinds)},
        "libraryDirectoryEntries": library_files,
        "libraryDirectoryFileCount": sum(1 for name in library_files
                                         if os.path.isfile(os.path.join(library, name))),
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    print(json.dumps(snapshot, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
