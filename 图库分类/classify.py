#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""图库图片分类引擎（只读）。

用途：读取 .assetframelibrary 的 global-material-library.sqlite，按
「产品名称映射表.json」把每张图片归到 品牌 / 茶类 / 产品线 / 机位 / 图类型 /
用途 / 比例 / 验收 / 整理状态，输出分类结果、覆盖率报告与筛选核验。

边界：
- 数据库以 mode=ro 打开，不写库、不改原素材。
- 纯规则，不调用任何模型，不联网。
- 结果写到本目录 输出/ 下，供图库界面读取，或经授权后回写素材标签。

用法：
  python3 图库分类/classify.py
  python3 图库分类/classify.py --db "/path/to/x.assetframelibrary/global-material-library.sqlite"
  python3 图库分类/classify.py --limit 200
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sqlite3
import sys
from collections import Counter, defaultdict
from math import gcd

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = "/Volumes/SSD-1TB/Ai资产管理/香万家木兰.assetframelibrary/global-material-library.sqlite"
OUT_DIR = os.path.join(HERE, "输出")


def load_mapping(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize(text: str) -> str:
    return (text or "").replace("\\", "/")


def scope_of(path: str, filename: str, asset_kind: str) -> str:
    """判定素材属于图库的哪一类；只有「产品图」参与品牌/茶类统计。"""
    text = normalize(path)
    if "/04_产品/" in text:
        return "产品图"
    if "/01_人物/" in text:
        return "人物图"
    if "分镜" in text or "/09_" in text:
        return "分镜图"
    if "场景资产" in text or "/03_场景" in text:
        return "场景图"
    if "Logo" in text or "VIS" in text or "视觉手册" in text:
        return "品牌资产"
    if asset_kind == "PPT页面":
        return "文档页面"
    return "其他素材"


def ratio_label(width: int, height: int, filename: str = "") -> str:
    if filename.lower().endswith(".svg"):
        return "矢量"
    if not width or not height:
        return "未知"
    divisor = gcd(width, height)
    w, h = width // divisor, height // divisor
    known = {(1, 1): "1:1", (4, 3): "4:3", (3, 4): "3:4", (16, 9): "16:9", (9, 16): "9:16", (3, 2): "3:2", (2, 3): "2:3"}
    if (w, h) in known:
        return known[(w, h)]
    value = width / height
    for target, label in ((1.0, "1:1"), (4 / 3, "4:3"), (3 / 4, "3:4"), (16 / 9, "16:9"), (9 / 16, "9:16")):
        if abs(value - target) <= 0.02:
            return label
    return "其他"


def first_hit(text: str, terms: list[str]) -> str | None:
    """按给定顺序返回首个命中的词，长词优先由调用方保证。"""
    for term in terms:
        if term and term in text:
            return term
    return None


class Classifier:
    def __init__(self, mapping: dict):
        self.mapping = mapping
        self.roots = set(mapping.get("project_root_names", []))
        self.brands = mapping["brands"]
        self.tea_types = mapping["tea_types"]
        self.product_lines = sorted(mapping["product_lines"], key=lambda item: max((len(p) for p in item["patterns"]), default=0), reverse=True)
        self.shots = mapping["shots"]
        self.asset_kinds = mapping["asset_kinds"]
        self.usages = mapping["usages"]

    def _segments(self, path: str) -> list[str]:
        return [seg for seg in normalize(path).split("/") if seg and seg not in self.roots]

    def _brand_in(self, text: str) -> list[str]:
        found = []
        for brand in self.brands:
            if any(alias in text for alias in brand["aliases"]):
                found.append(brand["name"])
        return found

    def _tea_in(self, text: str) -> str | None:
        for tea in self.tea_types:
            if first_hit(text, tea["terms"]):
                return tea["name"]
        return None

    def _product_line(self, text: str) -> dict | None:
        """同一段文字里取最长命中；调用方负责「文件名优先、其次目录」。"""
        best, best_len = None, 0
        for line in self.product_lines:
            for pattern in line["patterns"]:
                if pattern and pattern in text and len(pattern) > best_len:
                    best, best_len = line, len(pattern)
        return best

    def classify(self, material: dict) -> dict:
        path = normalize(material.get("sourcePath") or "")
        filename = f"{material.get('name') or ''} {material.get('originalFilename') or ''}"
        segments = self._segments(path)
        folder = " ".join(segments[:-1]) if len(segments) > 1 else ""
        full_text = f"{filename} {folder}"
        conflicts = []
        evidence = {}

        line = self._product_line(filename) or self._product_line(folder)

        # 品牌：文件名 > 产品线映射 > 目录段
        brand = None
        filename_brands = self._brand_in(filename)
        folder_brands = self._brand_in(folder)
        if filename_brands:
            brand = filename_brands[0]
            evidence["brand"] = "文件名"
            if len(set(filename_brands)) > 1:
                conflicts.append(f"文件名出现多个品牌：{sorted(set(filename_brands))}")
        elif line and line.get("brand"):
            brand = line["brand"]
            evidence["brand"] = f"产品线「{line['name']}」"
        elif folder_brands:
            brand = folder_brands[0]
            evidence["brand"] = "目录名"
            if len(set(folder_brands)) > 1:
                conflicts.append(f"目录出现多个品牌：{sorted(set(folder_brands))}")
        brand = brand or "未识别"

        # 茶类：文件名 > 目录 > 产品线
        tea = self._tea_in(filename)
        if tea:
            evidence["tea_type"] = "文件名"
        else:
            tea = self._tea_in(folder)
            if tea:
                evidence["tea_type"] = "目录名"
            elif line and line.get("tea_type"):
                tea = line["tea_type"]
                evidence["tea_type"] = f"产品线「{line['name']}」"
        if tea and line and line.get("tea_type") and line["tea_type"] != tea:
            conflicts.append(f"茶类冲突：文件/目录判为「{tea}」，产品线标注「{line['tea_type']}」")
        tea = tea or "未分类"

        # 机位
        shot = None
        for item in self.shots:
            if first_hit(filename, item["terms"]):
                shot = item["name"]
                evidence["shot"] = "文件名"
                break
        if not shot:
            for item in self.shots:
                if first_hit(folder, item["terms"]):
                    shot = item["name"]
                    evidence["shot"] = "目录名"
                    break
        shot = shot or "未标注"

        asset_kind = next((item["name"] for item in self.asset_kinds if first_hit(full_text, item["terms"])), "图片素材")
        usage = next((item["name"] for item in self.usages if item["terms"] and first_hit(full_text, item["terms"])), "设计素材")
        scope = scope_of(path, filename, asset_kind)

        meta = material.get("mediaMetadata") or {}
        ratio = ratio_label(int(meta.get("pixelWidth") or 0), int(meta.get("pixelHeight") or 0), material.get("originalFilename") or "")

        acceptance = "待核"
        for rule in self.mapping["acceptance_rules"]:
            if rule["terms"] and any(term in path for term in rule["terms"]):
                acceptance = rule["value"]
                break

        if scope != "产品图":
            # 非产品素材不参与品牌/茶类判定，避免用「未识别」污染产品覆盖率。
            brand, tea, shot = "不适用", "不适用", "不适用"
            line = None
            organize = "不适用"
        else:
            organize = "可用" if (acceptance == "已确认" and brand != "未识别" and tea != "未分类") else "待整理"
            if acceptance == "已确认" and (brand == "未识别" or tea == "未分类"):
                organize = "待补标签"

        return {
            "id": material.get("id"),
            "name": material.get("name") or "",
            "filename": material.get("originalFilename") or "",
            "path": path,
            "scope": scope,
            "brand": brand,
            "tea_type": tea,
            "product_line": line["name"] if line else ("不适用" if scope != "产品图" else "未归类"),
            "shot": shot,
            "asset_kind": asset_kind,
            "usage": usage,
            "ratio": ratio,
            "acceptance": acceptance,
            "organize_status": organize,
            "source": "本机引用",
            "evidence": evidence,
            "conflicts": conflicts,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--mapping", default=os.path.join(HERE, "产品名称映射表.json"))
    parser.add_argument("--out", default=OUT_DIR)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    if not os.path.exists(args.db):
        print(f"数据库不存在：{args.db}", file=sys.stderr)
        return 2

    classifier = Classifier(load_mapping(args.mapping))
    connection = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    rows = connection.execute("select payload from materials").fetchall()
    connection.close()

    records, skipped = [], 0
    for (payload,) in rows:
        material = json.loads(payload)
        if material.get("kind") != "图片":
            skipped += 1
            continue
        records.append(classifier.classify(material))
        if args.limit and len(records) >= args.limit:
            break

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "分类结果.json"), "w", encoding="utf-8") as handle:
        json.dump({"generatedFrom": args.db, "count": len(records), "records": records}, handle, ensure_ascii=False, indent=1)

    fields = ["id", "name", "scope", "brand", "tea_type", "product_line", "shot", "asset_kind", "usage", "ratio", "acceptance", "organize_status", "source", "path"]
    with open(os.path.join(args.out, "分类结果.csv"), "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for record in records:
            writer.writerow(record)

    facets = ["scope", "brand", "tea_type", "product_line", "shot", "asset_kind", "usage", "ratio", "acceptance", "organize_status"]
    counts = {facet: Counter(record[facet] for record in records) for facet in facets}
    products = [record for record in records if record["scope"] == "产品图"]
    unresolved = [record for record in products if record["brand"] == "未识别" or record["tea_type"] == "未分类"]
    conflicted = [record for record in records if record["conflicts"]]

    verify = {
        "total": len(records),
        "productCount": len(products),
        "facetTotals": {facet: sum(counts[facet].values()) for facet in facets},
        "consistent": all(sum(counts[facet].values()) == len(records) for facet in facets),
        "counts": {facet: dict(counts[facet].most_common()) for facet in facets},
        "conflictCount": len(conflicted),
        "unresolvedCount": len(unresolved),
    }
    with open(os.path.join(args.out, "筛选核验.json"), "w", encoding="utf-8") as handle:
        json.dump(verify, handle, ensure_ascii=False, indent=1)

    total = len(records) or 1
    product_total = len(products) or 1
    brand_ok = sum(1 for record in products if record["brand"] != "未识别")
    tea_ok = sum(1 for record in products if record["tea_type"] != "未分类")
    lines = [
        "# 图库图片分类 · 覆盖率报告",
        "",
        f"- 数据源：`{args.db}`",
        f"- 图片总数：**{len(records)}**（跳过非图片 {skipped} 条）",
        f"- 其中产品图：**{len(products)}** 张（图库主视图范围）",
        f"- 产品图品牌识别率：**{brand_ok / product_total * 100:.1f}%**（{brand_ok}/{len(products)}）",
        f"- 产品图茶类识别率：**{tea_ok / product_total * 100:.1f}%**（{tea_ok}/{len(products)}）",
        f"- 筛选一致性：{'全部维度计数之和等于总数 ✅' if verify['consistent'] else '存在不一致 ❌'}",
        f"- 产品图中未完全识别：**{len(unresolved)}** 张",
        f"- 规则冲突：**{len(conflicted)}** 张",
        "",
        "## 各维度分布",
        "",
    ]
    for facet in facets:
        lines.append(f"### {facet}")
        lines.append("")
        lines.append("| 取值 | 数量 | 占比 |")
        lines.append("| --- | ---: | ---: |")
        for value, count in counts[facet].most_common(12):
            lines.append(f"| {value} | {count} | {count / total * 100:.1f}% |")
        lines.append("")

    if conflicted:
        lines += ["## 冲突明细（前 20）", ""]
        for record in conflicted[:20]:
            lines.append(f"- `{record['name']}`：{'；'.join(record['conflicts'])}")
        lines.append("")

    if unresolved:
        lines += ["## 未识别样本（前 20）", ""]
        for record in unresolved[:20]:
            lines.append(f"- `{record['name']}` · 品牌={record['brand']} · 茶类={record['tea_type']}")
        lines.append("")

    with open(os.path.join(args.out, "覆盖率报告.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")

    print(f"图片 {len(records)} 张；未完全识别 {len(unresolved)}；冲突 {len(conflicted)}；筛选一致={verify['consistent']}")
    for facet in facets:
        top = "、".join(f"{k} {v}" for k, v in counts[facet].most_common(4))
        print(f"  {facet}: {top}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
