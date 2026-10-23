import Foundation

enum DeepSeekLibraryAuditClient {
    private struct RequestAsset: Encodable, Sendable {
        var id: String
        var name: String
        var type: String
        var tags: [String]
        var summary: String
    }

    private struct RequestIssue: Encodable, Sendable {
        var id: String
        var kind: String
        var severity: String
        var detail: String
        var assets: [RequestAsset]
    }

    private struct Envelope: Decodable, Sendable {
        var items: [RawSuggestion]
    }

    private struct RawSuggestion: Decodable, Sendable {
        var issueID: String
        var assetID: String?
        var proposedName: String?
        var assetType: String?
        var tags: [String]?
        var summary: String?
        var explanation: String
        var confidence: Double
    }

    static func analyze(
        issues: [LibraryAuditIssue],
        assets: [AssetItem],
        configuration: DeepSeekConfiguration
    ) async throws -> [LibraryAuditSuggestion] {
        guard !issues.isEmpty else { return [] }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var suggestions: [LibraryAuditSuggestion] = []
        for start in stride(from: 0, to: issues.count, by: 40) {
            let end = min(start + 40, issues.count)
            let batch = Array(issues[start..<end])
            suggestions.append(contentsOf: try await analyzeBatch(
                issues: batch,
                assetsByID: assetsByID,
                configuration: configuration
            ))
        }
        return suggestions
    }

    private static func analyzeBatch(
        issues: [LibraryAuditIssue],
        assetsByID: [String: AssetItem],
        configuration: DeepSeekConfiguration
    ) async throws -> [LibraryAuditSuggestion] {
        let payload = issues.map { issue in
            RequestIssue(
                id: issue.id,
                kind: issue.kind.rawValue,
                severity: issue.severity.rawValue,
                detail: issue.detail,
                assets: issue.assetIDs.compactMap { id in
                    guard let asset = assetsByID[id] else { return nil }
                    return RequestAsset(
                        id: asset.id,
                        name: asset.name,
                        type: asset.type.rawValue,
                        tags: asset.normalizedTags,
                        summary: asset.assetDescription
                    )
                }
            )
        }
        let input = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let allowedTypes = AssetType.allCases.map(\.rawValue).joined(separator: "、")
        let systemPrompt = """
        你是短剧资产库质量检查员。以下问题均由本地规则先发现，你只负责解释问题，并在有充分依据时建议安全的文字字段。
        允许建议的字段只有：资产名称、资产类型、标签、资产说明。资产类型只能是：\(allowedTypes)。
        禁止建议或声称已经执行：删除资产、替换主图、锁定形态、修改调用编号、修改版本、修改文件指纹、修改源文件。
        没有足够依据时只给 explanation，不要猜测名称或类型。
        必须返回 json：
        {"items":[{"issueID":"原问题id","assetID":"可选且必须属于该问题","proposedName":null,"assetType":null,"tags":[],"summary":null,"explanation":"简短处理建议","confidence":0.0}]}
        """
        return try await DeepSeekChatClient.requestJSON(
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPrompt: "请分析以下资产库体检问题并返回 json：\n\(input)",
            maxTokens: 16_000
        ) { content in
            try decode(
                content,
                issuesByID: Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) }),
                allowedAssetIDs: Set(assetsByID.keys)
            )
        }
    }

    static func decode(
        _ content: String,
        issuesByID: [String: LibraryAuditIssue],
        allowedAssetIDs: Set<String>
    ) throws -> [LibraryAuditSuggestion] {
        let cleaned = content
            .replacing("```json", with: "")
            .replacing("```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw DeepSeekClientError.invalidJSON
        }

        return envelope.items.compactMap { raw in
            guard let issue = issuesByID[raw.issueID] else { return nil }
            let assetID = raw.assetID.flatMap { id in
                issue.assetIDs.contains(id) && allowedAssetIDs.contains(id) ? id : nil
            }
            let assetType = raw.assetType.flatMap(AssetType.init(rawValue:))
            return LibraryAuditSuggestion(
                issueID: raw.issueID,
                assetID: assetID,
                proposedName: cleanedOptional(raw.proposedName),
                assetType: assetType,
                tags: normalized(raw.tags ?? []),
                summary: cleanedOptional(raw.summary),
                explanation: raw.explanation.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: min(1, max(0, raw.confidence))
            )
        }
    }

    private static func cleanedOptional(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
