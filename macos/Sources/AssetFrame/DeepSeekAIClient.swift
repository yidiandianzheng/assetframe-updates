import Foundation

enum DeepSeekAIClient {
    private struct RequestItem: Encodable, Sendable {
        var id: String
        var filename: String
        var relativePath: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var currentType: String
        var currentCategory: String
    }

    private struct SuggestionEnvelope: Decodable {
        var items: [RawSuggestion]
    }

    private struct RawSuggestion: Decodable {
        var id: String
        var proposedName: String
        var assetType: String
        var styleTags: [String]
        var summary: String
        var confidence: Double
    }

    static func analyze(
        items: [PendingImportItem],
        projectRoot: URL,
        configuration: DeepSeekConfiguration
    ) async throws -> [PendingAIAnalysisSuggestion] {
        guard !items.isEmpty else { return [] }
        var suggestions: [PendingAIAnalysisSuggestion] = []
        for start in stride(from: 0, to: items.count, by: 40) {
            let end = min(start + 40, items.count)
            suggestions.append(contentsOf: try await analyzeBatch(
                Array(items[start..<end]),
                projectRoot: projectRoot,
                configuration: configuration
            ))
        }
        return suggestions
    }

    static func requestPayload(items: [PendingImportItem], projectRoot: URL) throws -> String {
        let payload = items.map { item in
            RequestItem(
                id: item.id,
                filename: item.originalFilename,
                relativePath: relativeSourcePath(item.originalSourcePath, projectRoot: projectRoot),
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                currentType: item.suggestedType.rawValue,
                currentCategory: item.category.rawValue
            )
        }
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    private static func analyzeBatch(
        _ items: [PendingImportItem],
        projectRoot: URL,
        configuration: DeepSeekConfiguration
    ) async throws -> [PendingAIAnalysisSuggestion] {
        let inputJSON = try requestPayload(items: items, projectRoot: projectRoot)
        let allowedTypes = AssetType.allCases.map(\.rawValue).joined(separator: "、")
        let systemPrompt = """
        你是短剧视觉资产库管理员。你收到的只是文件名、项目内相对路径、像素尺寸和人工已有分类，没有看到图片像素，不得声称看到了画面。
        请仅根据现有文本信息提供保守的分类建议。资产类型只能是：\(allowedTypes)。
        必须返回 json 对象，格式为：
        {"items":[{"id":"原id","proposedName":"建议中文名称","assetType":"允许的类型","styleTags":[],"summary":"简短说明","confidence":0.0}]}
        文件名不足以判断美术风格时，styleTags 返回空数组；不要猜测。confidence 范围为 0 到 1。
        """
        return try await DeepSeekChatClient.requestJSON(
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPrompt: "请分析以下待导入资产并返回 json：\n\(inputJSON)",
            maxTokens: 12_000
        ) { content in
            try decodeSuggestions(content: content, allowedIDs: Set(items.map(\.id)))
        }
    }

    static func decodeSuggestions(content: String, allowedIDs: Set<String>) throws -> [PendingAIAnalysisSuggestion] {
        let cleaned = content
            .replacing("```json", with: "")
            .replacing("```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else { throw DeepSeekClientError.invalidResponse }
        let envelope = try JSONDecoder().decode(SuggestionEnvelope.self, from: data)
        return envelope.items.compactMap { raw in
            guard allowedIDs.contains(raw.id), let type = AssetType(rawValue: raw.assetType) else { return nil }
            return PendingAIAnalysisSuggestion(
                itemID: raw.id,
                proposedName: raw.proposedName.trimmingCharacters(in: .whitespacesAndNewlines),
                assetType: type,
                styleTags: Array(Set(raw.styleTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(),
                summary: raw.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: min(1, max(0, raw.confidence)),
                analyzedAt: .now
            )
        }
    }

    private static func relativeSourcePath(_ path: String, projectRoot: URL) -> String? {
        let sourcePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let rootPath = projectRoot.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard sourcePath.hasPrefix(prefix) else { return nil }
        let relative = String(sourcePath.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}
