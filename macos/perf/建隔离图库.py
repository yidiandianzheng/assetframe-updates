#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""建流畅度基线用的隔离图库副本（只读生产库，绝不写生产库与原素材）。

做法：
1. 生产库里每条素材引用的绝对路径，在 <QA根>/mirror 下按同样的目录结构建符号链接指回原文件；
   这样既保住「目录名参与分类与分组」的真实性，又不把 5.1GB 图片压进只剩 14Gi 的启动盘。
2. 整份复制 .assetframelibrary（SQLite 只有 16MiB），把 payload 里的 sourcePath / sourceLocations /
   sourceURL 改写为镜像路径；库 ID 保持不变，browse 状态文件名才能对上。
3. 写 <QA根>/libraries.json 指向副本，并复制该库的 browse-<id>.json（scope 同步改写）。

已知代价：payload 里 lightweight 导入的 `source:SHA256(路径|大小|修改时间)` 指纹会因路径变化而失效；
内容指纹与浏览、缩略图、筛选、滚动无关，实测里会体现为「重扫时判为已变化」，不影响本测量。
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

PRODUCTION_LIBRARY = "/Volumes/SSD-1TB/Ai资产管理/香万家木兰.assetframelibrary"
PRODUCTION_REGISTRY = os.path.expanduser("~/Library/Application Support/AssetFrame")
PATH_KEYS = ("sourcePath", "sourceURL")


def mirror_path(mirror_root: str, original: str) -> str:
    return mirror_root + original if original.startswith("/") else os.path.join(mirror_root, original)


def collect_paths(rows):
    paths = set()
    for payload in rows:
        record = json.loads(payload)
        for key in PATH_KEYS:
            value = record.get(key)
            if isinstance(value, str) and value.startswith("/"):
                paths.add(value)
        for value in record.get("sourceLocations") or []:
            if isinstance(value, str) and value.startswith("/"):
                paths.add(value)
    return sorted(paths)


def build_links(mirror_root: str, paths):
    created = existing_target = dangling = 0
    directories = set()
    for original in paths:
        link = mirror_path(mirror_root, original)
        parent = os.path.dirname(link)
        if parent not in directories:
            os.makedirs(parent, exist_ok=True)
            directories.add(parent)
        if os.path.islink(link):
            created += 1
            continue
        try:
            os.symlink(original, link)
            created += 1
        except FileExistsError:
            created += 1
        except OSError:
            dangling += 1
            continue
        if os.path.isfile(original):
            existing_target += 1
    return created, existing_target, dangling


def rewrite_payload(payload: str, mirror_root: str) -> str:
    record = json.loads(payload)
    changed = False
    for key in PATH_KEYS:
        value = record.get(key)
        if isinstance(value, str) and value.startswith("/"):
            record[key] = mirror_path(mirror_root, value)
            changed = True
    locations = record.get("sourceLocations")
    if isinstance(locations, list) and locations:
        record["sourceLocations"] = [
            mirror_path(mirror_root, item) if isinstance(item, str) and item.startswith("/") else item
            for item in locations
        ]
        changed = True
    return json.dumps(record, ensure_ascii=False) if changed else payload


def rewrite_json(value, mirror_root: str):
    """递归把状态 JSON 里的绝对路径改到镜像根下；只认已知挂载根，避免误改备注文本。"""
    if isinstance(value, str):
        return mirror_path(mirror_root, value) if value.startswith(("/Volumes/", "/Users/")) else value
    if isinstance(value, list):
        return [rewrite_json(item, mirror_root) for item in value]
    if isinstance(value, dict):
        return {key: rewrite_json(item, mirror_root) for key, item in value.items()}
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", default=PRODUCTION_LIBRARY)
    parser.add_argument("--root", default="", help="QA 根，缺省自动 mktemp -d /tmp/assetframe-qa.perf.XXXXXX")
    parser.add_argument("--registry", default=PRODUCTION_REGISTRY)
    parser.add_argument("--thumbnail-size", type=int, default=116, help="写进 browse 状态的缩略图边长（像素）")
    args = parser.parse_args()

    # App 侧只接受 /tmp 或 /private/tmp 的直接子项且前缀 assetframe-qa.，不合规则直接 fatalError。
    root = args.root or subprocess.run(
        ["mktemp", "-d", "/tmp/assetframe-qa.perf.XXXXXX"], capture_output=True, text=True, check=True
    ).stdout.strip()
    mirror_root = os.path.join(root, "mirror")
    os.makedirs(mirror_root, exist_ok=True)

    source_db = os.path.join(args.library, "global-material-library.sqlite")
    read = sqlite3.connect("file:%s?mode=ro" % source_db, uri=True)
    rows = read.execute("select id, payload from materials").fetchall()
    library_id = json.load(open(os.path.join(args.library, "assetframe-library.json")))["id"]
    before_check = read.execute("pragma quick_check").fetchone()[0]
    referenced = collect_paths([payload for _, payload in rows])
    read.close()

    started = time.time()
    links, real_targets, dangling = build_links(mirror_root, referenced)

    library_copy = os.path.join(root, os.path.basename(args.library))
    if os.path.exists(library_copy):
        shutil.rmtree(library_copy)
    shutil.copytree(args.library, library_copy, ignore=shutil.ignore_patterns(".writer.lock"))

    copy_db = os.path.join(library_copy, "global-material-library.sqlite")
    write = sqlite3.connect(copy_db)
    rewritten = 0
    state_rewritten = []
    with write:
        for material_id, payload in rows:
            updated = rewrite_payload(payload, mirror_root)
            if updated != payload:
                write.execute("update materials set payload = ? where id = ?", (updated, material_id))
                rewritten += 1
        # 侧栏文件夹树来自 organization.folders[].rootPath，不改写的话它会去扫原始卷，
        # 既测不到复制出来的图库，也会让文件夹计数全为 0。
        for table in ("organization", "history", "presets", "links"):
            for row_id, payload in write.execute("select id, payload from %s" % table).fetchall():
                text = payload.decode("utf-8") if isinstance(payload, (bytes, bytearray)) else str(payload)
                updated = json.dumps(rewrite_json(json.loads(text), mirror_root), ensure_ascii=False)
                if updated != text:
                    write.execute("update %s set payload = ? where id = ?" % table, (updated, row_id))
                    state_rewritten.append("%s/%s" % (table, row_id))
    after_check = write.execute("pragma quick_check").fetchone()[0]
    sample = write.execute("select payload from materials limit 1").fetchone()[0]
    organization_row = write.execute("select payload from organization").fetchone()
    organization = json.loads((organization_row[0].decode("utf-8") if isinstance(organization_row[0], (bytes, bytearray))
                               else organization_row[0])) if organization_row else {}
    folder_roots = [folder["rootPath"] for folder in organization.get("folders") or []]
    write.close()

    json.dump(
        {"currentID": library_id, "locations": [{"id": library_id, "path": library_copy,
                                                 "name": os.path.basename(args.library).replace(".assetframelibrary", "")}]},
        open(os.path.join(root, "libraries.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    browse_source = os.path.join(args.registry, "browse-%s.json" % library_id)
    if os.path.isfile(browse_source):
        browse = json.load(open(browse_source, encoding="utf-8"))
        # 测量要的是「满屏缩略图」这一种最重场景，所以固定回到全部素材、只看图片，
        # 并清掉上次退出留下的文件夹范围、锚点和选中项，保证每次启动初始状态一致。
        browse["scope"] = "all"
        browse["search"] = ""
        browse.setdefault("filter", {})["kinds"] = ["图片"]
        browse["scrollY"] = 0
        browse["selected"] = []
        browse.pop("scrollAnchor", None)
        browse.pop("focused", None)
        browse.setdefault("display", {})["thumbnailSize"] = args.thumbnail_size
        json.dump(browse, open(os.path.join(root, "browse-%s.json" % library_id), "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)

    summary = {
        "builtAt": datetime.datetime.now().isoformat(timespec="seconds"),
        "qaRoot": root,
        "mirrorRoot": mirror_root,
        "libraryCopy": library_copy,
        "libraryID": library_id,
        "records": len(rows),
        "recordsRewritten": rewritten,
        "stateTablesRewritten": state_rewritten,
        "folderRootPaths": folder_roots,
        "referencedPaths": len(referenced),
        "symlinksCreated": links,
        "symlinksToExistingTarget": real_targets,
        "symlinksDangling": dangling,
        "productionQuickCheckBeforeRead": before_check,
        "copyQuickCheck": after_check,
        "firstSourcePath": json.loads(sample).get("sourcePath"),
        "elapsedSeconds": round(time.time() - started, 1),
        "qaRootDiskUsage": subprocess.run(["du", "-sh", root], capture_output=True, text=True).stdout.split()[0],
    }
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
