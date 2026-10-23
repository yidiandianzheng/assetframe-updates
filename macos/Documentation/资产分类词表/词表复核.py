#!/usr/bin/env python3
"""按 数据来源清单.csv 重算词表频次，检查词表与语料是否漂移（只读，不联网）。

用法：python3 词表复核.py
输出：每个词条的 提示词文件数/出现次数，以及与 词表_v0.1.json 记录的差异。
"""
import csv, hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "数据来源清单.csv")
VOCAB = os.path.join(HERE, "词表_v0.1.json")


def matcher(aliases):
    pats = []
    for a in aliases:
        al = a.lower()
        if re.search(r"[a-z0-9]", al) and not re.search(r"[\u4e00-\u9fa5]", al):
            pats.append(re.compile(r"(?<![a-z0-9])" + re.escape(al) + r"(?![a-z0-9])"))
        else:
            pats.append(al)
    return pats


def main():
    if not os.path.exists(SOURCES) or not os.path.exists(VOCAB):
        sys.exit("缺少 数据来源清单.csv 或 词表_v0.1.json")
    docs = []
    seen = set()
    with open(SOURCES, encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            path = row["来源路径"]
            try:
                raw = open(path, encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            if path.lower().endswith(".json"):
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                parts = [d.get(k) for k in ("prompt", "positive_prompt", "text")] if isinstance(d, dict) else []
                raw = "\n".join(x for x in parts if isinstance(x, str))
                if not raw:
                    continue
            digest = hashlib.sha1(re.sub(r"\s+", "", raw).encode()).hexdigest()
            if digest in seen:
                continue
            seen.add(digest)
            docs.append(raw.lower())
    vocab = json.load(open(VOCAB, encoding="utf-8"))
    drift = 0
    for t in vocab["terms"]:
        df = 0
        for text in docs:
            for p in matcher(t["aliases"]):
                n = text.count(p) if isinstance(p, str) else len(p.findall(text))
                if n:
                    df += 1
                    break
        if df != t["promptDocFreq"]:
            drift += 1
            print(f"漂移 {t['dimension']}/{t['canonical']}: 记录 {t['promptDocFreq']} → 现在 {df}")
    print(f"复核完成：{len(docs)} 份可读文档，{len(vocab['terms'])} 条词，漂移 {drift} 条")


if __name__ == "__main__":
    main()
