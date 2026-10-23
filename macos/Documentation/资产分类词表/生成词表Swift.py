#!/usr/bin/env python3
"""把 词表_v0.1.json 生成为 App 内置 Swift 词表。

用法：
    python3 生成词表Swift.py [词表json] [输出swift]
默认读写本目录的 词表_v0.1.json → macos/Sources/AssetFrame/ClassificationVocabulary.swift
词表升级（v0.2）时只替换输入 JSON 再运行本脚本，App 内维度/词条即更新。
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "词表_v0.1.json")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.abspath(
    os.path.join(HERE, "..", "..", "Sources", "AssetFrame", "ClassificationVocabulary.swift"))


def swift_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    data = json.load(open(SRC, encoding="utf-8"))
    dims = data["dimensions"]
    terms = sorted(data["terms"], key=lambda t: ([d["id"] for d in dims].index(t["dimension"]),
                                                 {"推荐": 0, "候选": 1, "项目实体": 2}.get(t["status"], 9),
                                                 -int(t.get("evidence", 0)), t["canonical"]))
    lines = []
    lines.append("// 由 macos/Documentation/资产分类词表/生成词表Swift.py 生成，请勿手改。")
    lines.append("// 词表来源：macos/Documentation/资产分类词表/词表_v0.1.json（%s）" % data.get("version", "0.1"))
    lines.append("// 更新流程：替换 JSON → 运行 生成词表Swift.py → 构建 → 隔离库验证。")
    lines.append("import Foundation")
    lines.append("")
    lines.append("struct ClassificationDimension: Identifiable, Hashable, Sendable {")
    lines.append("    let id: String")
    lines.append("    let name: String")
    lines.append("    let allowsMultiple: Bool")
    lines.append("    let summary: String")
    lines.append("}")
    lines.append("")
    lines.append("struct ClassificationTerm: Identifiable, Hashable, Sendable {")
    lines.append("    let dimension: String")
    lines.append("    let canonical: String")
    lines.append("    let aliases: [String]")
    lines.append("    let status: String")
    lines.append("    let scope: String")
    lines.append("    let note: String")
    lines.append("    let promptDocFreq: Int")
    lines.append("    let fileEvidence: Int")
    lines.append("    var id: String { dimension + \":\" + canonical }")
    lines.append("    var evidence: Int { promptDocFreq + fileEvidence }")
    lines.append("}")
    lines.append("")
    lines.append("/// 内置受控分类词表。备注仍为自由文本，分类值只从这里取值。")
    lines.append("enum ClassificationVocabulary {")
    lines.append("    static let version = %s" % swift_string(data.get("version", "0.1")))
    lines.append("    static let dimensions: [ClassificationDimension] = [")
    for d in dims:
        allows = "false" if d.get("mode") == "单选" else "true"
        lines.append("        .init(id: %s, name: %s, allowsMultiple: %s, summary: %s),"
                     % (swift_string(d["id"]), swift_string(d["name"]), allows, swift_string(d.get("description", ""))))
    lines.append("    ]")
    lines.append("    static let terms: [ClassificationTerm] = [")
    for t in terms:
        aliases = ", ".join(swift_string(a) for a in t.get("aliases", []))
        lines.append("        .init(dimension: %s, canonical: %s, aliases: [%s], status: %s, scope: %s, note: %s, promptDocFreq: %d, fileEvidence: %d),"
                     % (swift_string(t["dimension"]), swift_string(t["canonical"]), aliases,
                        swift_string(t["status"]), swift_string(t["scope"]), swift_string(t.get("note", "")),
                        int(t.get("promptDocFreq", 0)), int(t.get("fileEvidence", 0))))
    lines.append("    ]")
    lines.append("")
    lines.append("    static func dimension(_ id: String) -> ClassificationDimension? { dimensions.first { $0.id == id } }")
    lines.append("    static func terms(in dimension: String) -> [ClassificationTerm] { terms.filter { $0.dimension == dimension } }")
    lines.append("    static func term(_ canonical: String, in dimension: String) -> ClassificationTerm? {")
    lines.append("        terms.first { $0.dimension == dimension && $0.canonical == canonical }")
    lines.append("    }")
    lines.append("    static func allowsMultiple(_ id: String) -> Bool { dimensions.first { $0.id == id }?.allowsMultiple ?? true }")
    lines.append("    static var termCount: Int { terms.count }")
    lines.append("    static var recommendedCount: Int { terms.filter { $0.status == \"推荐\" }.count }")
    lines.append("}")
    open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("generated", OUT, len(lines), "lines,", len(terms), "terms,", len(dims), "dimensions")


if __name__ == "__main__":
    main()
