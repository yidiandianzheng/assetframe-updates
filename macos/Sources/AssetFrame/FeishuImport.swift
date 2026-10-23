import Foundation

enum AssetDeliveryCSV {
    static let headers = [
        "项目", "调用编号", "资产类型", "资产名称", "形态名称", "正式状态", "主图文件名", "补图1", "补图2",
        "形态关键区别", "禁止混用", "复用等级", "所属集数", "审核结果", "资产版本", "交付版本",
        "最后修改时间", "主图指纹", "Hotdesk调用说明", "备注"
    ]

    static let protectedHeaders = Set(["调用编号", "主图文件名", "补图1", "补图2", "资产版本", "主图指纹"])
    static let editableHeaders = Set(["资产名称", "形态名称", "形态关键区别", "禁止混用", "复用等级", "所属集数", "审核结果", "备注"])
}

struct FeishuImportFieldChange: Identifiable, Hashable, Sendable {
    var id: String { "\(variantID)|\(field)" }
    var variantID: String
    var callCode: String
    var field: String
    var oldValue: String
    var newValue: String
}

struct FeishuImportPreview: Identifiable, Sendable {
    let id = UUID()
    var sourceURL: URL
    var changes: [FeishuImportFieldChange]
    var errors: [String]
    var matchedCount: Int

    var canApply: Bool { errors.isEmpty && !changes.isEmpty }
}

enum CSVDocumentError: Error, LocalizedError {
    case empty
    case missingHeaders([String])

    var errorDescription: String? {
        switch self {
        case .empty: "CSV 没有可读取的内容。"
        case .missingHeaders(let values): "CSV 缺少字段：\(values.joined(separator: "、"))"
        }
    }
}

enum CSVDocument {
    static func read(url: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let matrix = parse(text)
        guard let header = matrix.first, !header.isEmpty else { throw CSVDocumentError.empty }
        let normalizedHeader = header.enumerated().map { index, value in
            index == 0 ? value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) : value
        }
        let missing = ["调用编号"].filter { !normalizedHeader.contains($0) }
        guard missing.isEmpty else { throw CSVDocumentError.missingHeaders(missing) }
        return matrix.dropFirst().filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }.map { row in
            Dictionary(uniqueKeysWithValues: normalizedHeader.enumerated().map { index, key in
                (key, index < row.count ? row[index] : "")
            })
        }
    }

    /// RFC 4180 子集：支持逗号、CRLF、引号字段与双引号转义，足够覆盖飞书 CSV 导入导出。
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
