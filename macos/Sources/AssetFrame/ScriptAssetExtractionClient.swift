import AppKit
import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum ScriptDocumentReader {
    static var supportedTypes: [UTType] {
        var values: [UTType] = [.plainText, .utf8PlainText, .rtf, .pdf]
        if let markdown = UTType(filenameExtension: "md") { values.append(markdown) }
        if let markdown = UTType(filenameExtension: "markdown") { values.append(markdown) }
        if let fountain = UTType(filenameExtension: "fountain") { values.append(fountain) }
        return values
    }

    static func read(url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url), let text = document.string, !text.isEmpty else {
                throw ScriptExtractionError.unreadableDocument
            }
            return text
        case "rtf", "rtfd":
            let value = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
            guard !value.isEmpty else { throw ScriptExtractionError.unreadableDocument }
            return value
        default:
            if let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty { return value }
            var usedEncoding = String.Encoding.utf8
            let value = try String(contentsOf: url, usedEncoding: &usedEncoding)
            guard !value.isEmpty else { throw ScriptExtractionError.unreadableDocument }
            return value
        }
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ScriptAssetExtractionClient {
    private struct Envelope: Decodable, Sendable { var items: [RawCandidate] }
    private struct RawCandidate: Decodable, Sendable {
        var name: String
        var assetType: String
        var formName: String?
        var reuseGrade: String
        var appearances: [String]
        var evidence: String
        var note: String
    }

    static func extract(
        text: String,
        sourceName: String,
        configuration: DeepSeekConfiguration,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void
    ) async throws -> [ScriptAssetCandidate] {
        let chunks = makeChunks(text)
        guard !chunks.isEmpty else { throw ScriptExtractionError.emptyDocument }
        var all: [ScriptAssetCandidate] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let candidates = try await analyzeChunk(
                chunk,
                sourceName: sourceName,
                chunkIndex: index + 1,
                chunkCount: chunks.count,
                configuration: configuration
            )
            all.append(contentsOf: candidates)
            await progress(index + 1, chunks.count)
        }
        return merge(candidates: all)
    }

    private static func analyzeChunk(
        _ text: String,
        sourceName: String,
        chunkIndex: Int,
        chunkCount: Int,
        configuration: DeepSeekConfiguration
    ) async throws -> [ScriptAssetCandidate] {
        let systemPrompt = """
        你是短剧视觉资产拆解员。只从用户原文中提取需要制作或复用的视觉资产，禁止改写剧情和补充原文没有的设定。
        只允许三种资产类型：人物、场景、道具。
        人物：有明确身份、反复出场或需要保持外观一致的角色；同一人物的同一稳定形态跨场次只保留一条。
        场景：需要保持空间、时代、结构或陈设一致的地点；机位、普通光线和气氛不是新场景。
        道具：对剧情有作用、跨镜头复现或需要保持形制一致的物件；普通一次性小物件跳过。
        形态只记录会持续影响造型的变化：人物换装、战损、变身、年龄变化；场景昼夜、损毁、污染；道具损坏或稳定状态。表情、姿势、机位、短暂动作和短暂光效不得拆成形态。
        同一主体出现两个或更多稳定视觉状态时，必须为每个状态分别返回一条 item：name 和 assetType 保持相同，formName 必须明确区分，appearances、evidence 和 note 只写该形态自己的内容。严禁只返回一条“基础”，再把多个形态塞进 evidence 或 note。
        必须拆分的典型情况：穿越前现代装 / 穿越后古代装；流放前身份装 / 流放后劳作装；前期未佩戴 / 后期持续佩戴手镯、面具、盔甲等可见标志；基础 / 换装；正常 / 持续战损；变身前 / 变身后；白天 / 夜晚；完好 / 损毁。
        时间变化本身不是形态；只有服装、发型、持续伤势、年龄、材质、结构或长期佩戴标志发生可见且持续的变化时才拆分。
        示例：原文写“某角色穿越前穿现代睡衣，穿越后长期穿粗布工衣”，必须输出两条同名人物，formName 分别为“穿越前·现代装”和“穿越后·古代装”。
        示例：原文写“某角色后期右腕长期戴罪籍手镯”，基础状态不带手镯，必须输出“流放初期·无罪籍手镯”和“后期·罪籍手镯”两条同名人物。
        不得把台词、动作、情绪、关系、运镜、镜头、光效、氛围、冲突、剧情节点、抽象概念当资产。
        复用等级只能是 S、A、B、C：S 主线高频且必须稳定；A 关键场次复用；B 局部使用；C 低频背景。
        必须返回 JSON 对象：
        {"items":[{"name":"稳定主体名称","assetType":"人物|场景|道具","formName":"基础|换装名|战损|夜景|损毁等稳定形态","reuseGrade":"S|A|B|C","appearances":["第1集第2场或镜头编号"],"evidence":"原文中的简短依据","note":"为什么需要资产化；不确定时写待确认"}]}
        证据保持简短，不要大段复制原文。没有符合条件的资产时返回 {"items":[]}。
        """
        let userPrompt = """
        文件：\(sourceName)
        当前分段：\(chunkIndex)/\(chunkCount)
        请拆解以下剧本文本中的人物、场景、道具，返回 JSON：

        \(text)
        """
        return try await DeepSeekChatClient.requestJSON(
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 24_000
        ) { content in
            let candidates = try decode(content)
            try validateSeparatedForms(candidates)
            return candidates
        }
    }

    static func decode(_ content: String) throws -> [ScriptAssetCandidate] {
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ScriptExtractionError.invalidResponse
        }
        return envelope.items.compactMap { raw in
            let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let type = allowedType(raw.assetType) else { return nil }
            return ScriptAssetCandidate(
                id: UUID().uuidString,
                name: name,
                type: type,
                reuse: reuseGrade(raw.reuseGrade),
                appearances: normalized(raw.appearances),
                evidence: raw.evidence.trimmingCharacters(in: .whitespacesAndNewlines),
                note: raw.note.trimmingCharacters(in: .whitespacesAndNewlines),
                status: .pending,
                formName: normalizedFormName(raw.formName),
                isRequired: true,
                linkedVariantID: nil,
                linkState: .pending,
                reviewedAt: nil
            )
        }
    }

    static func validateSeparatedForms(_ candidates: [ScriptAssetCandidate]) throws {
        let grouped = Dictionary(grouping: candidates) { candidate in
            let normalizedName = candidate.name
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            return "\(candidate.type.rawValue)|\(normalizedName)"
        }

        for group in grouped.values {
            guard let first = group.first else { continue }
            let combined = group.map { "\($0.evidence) \($0.note)" }.joined(separator: " ")
            guard describesMultipleStableForms(combined) else { continue }
            let forms = Set(group.map { $0.effectiveFormName.trimmingCharacters(in: .whitespacesAndNewlines) })
            if forms.count < 2 {
                throw ScriptExtractionError.unseparatedForms(first.name)
            }
        }
    }

    private static func makeChunks(_ text: String, limit: Int = 12_000) -> [String] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var chunks: [String] = []
        var current = ""
        for paragraph in normalizedText.components(separatedBy: "\n\n") {
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                var start = value.startIndex
                while start < value.endIndex {
                    let end = value.index(start, offsetBy: limit, limitedBy: value.endIndex) ?? value.endIndex
                    chunks.append(String(value[start..<end]))
                    start = end
                }
            } else if current.count + value.count + 2 > limit {
                chunks.append(current)
                current = value
            } else {
                current += current.isEmpty ? value : "\n\n\(value)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func estimatedChunkCount(for text: String) -> Int {
        max(1, makeChunks(text).count)
    }

    private static func merge(candidates: [ScriptAssetCandidate]) -> [ScriptAssetCandidate] {
        var result: [ScriptAssetCandidate] = []
        var indexByKey: [String: Int] = [:]
        for candidate in candidates {
            let normalizedName = candidate.name
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            let normalizedForm = candidate.effectiveFormName
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            let key = "\(candidate.type.rawValue)|\(normalizedName)|\(normalizedForm)"
            if let index = indexByKey[key] {
                result[index].appearances = normalized(result[index].appearances + candidate.appearances)
                result[index].reuse = higherPriority(result[index].reuse, candidate.reuse)
                if !candidate.evidence.isEmpty, !result[index].evidence.contains(candidate.evidence) {
                    result[index].evidence += result[index].evidence.isEmpty ? candidate.evidence : "；\(candidate.evidence)"
                }
                if result[index].note.isEmpty { result[index].note = candidate.note }
            } else {
                indexByKey[key] = result.count
                result.append(candidate)
            }
        }
        return result.sorted {
            if $0.type != $1.type { return typeOrder($0.type) < typeOrder($1.type) }
            if $0.reuse != $1.reuse { return gradeOrder($0.reuse) < gradeOrder($1.reuse) }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.effectiveFormName.localizedStandardCompare($1.effectiveFormName) == .orderedAscending
        }
    }

    private static func describesMultipleStableForms(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        let contrastPairs = [
            ("穿越前", "穿越后"), ("现代装", "古代装"), ("现代装扮", "古代装扮"),
            ("流放前", "流放后"), ("前期", "后期"), ("变身前", "变身后"),
            ("战损前", "战损后"), ("白天", "夜晚"), ("完好", "损毁"),
            ("未佩戴", "佩戴"), ("无手镯", "戴手镯")
        ]
        if contrastPairs.contains(where: { compact.contains($0.0) && compact.contains($0.1) }) { return true }

        let laterMarkers = ["后期", "之后", "后来"]
        let persistentVisualChanges = ["长期戴", "持续戴", "长期佩戴", "持续佩戴", "右腕戴", "换装", "战损", "变身"]
        return laterMarkers.contains(where: compact.contains) && persistentVisualChanges.contains(where: compact.contains)
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }

    private static func normalizedFormName(_ value: String?) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "基础" : text
    }

    private static func allowedType(_ value: String) -> AssetType? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["人物", "角色", "生物"].contains(text) { return .person }
        if ["场景", "场地", "地点"].contains(text) { return .scene }
        if ["道具", "物件", "物品"].contains(text) { return .prop }
        return nil
    }

    private static func reuseGrade(_ value: String) -> ReuseGrade {
        return switch value.uppercased().first { case "S": .s; case "A": .a; case "C": .c; default: .b }
    }
    private static func higherPriority(_ lhs: ReuseGrade, _ rhs: ReuseGrade) -> ReuseGrade {
        gradeOrder(lhs) <= gradeOrder(rhs) ? lhs : rhs
    }
    private static func gradeOrder(_ value: ReuseGrade) -> Int {
        return switch value { case .s: 0; case .a: 1; case .b: 2; case .c: 3 }
    }
    private static func typeOrder(_ value: AssetType) -> Int {
        return switch value { case .person: 0; case .scene: 1; case .prop: 2; default: 3 }
    }

}

enum ScriptExtractionError: LocalizedError {
    case emptyDocument
    case unreadableDocument
    case invalidResponse
    case unseparatedForms(String)

    var errorDescription: String? {
        switch self {
        case .emptyDocument: "剧本文件没有可读取的文字"
        case .unreadableDocument: "无法读取该剧本文件，请改用 MD、TXT、RTF 或可复制文字的 PDF"
        case .invalidResponse: "AI 返回了无法识别的剧本资产清单"
        case let .unseparatedForms(name): "AI 将“\(name)”的多个稳定形态合并在一行，请重新分析"
        }
    }
}
