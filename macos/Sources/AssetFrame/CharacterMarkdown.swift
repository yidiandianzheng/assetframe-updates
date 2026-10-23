import Foundation
import CryptoKit

/// A bounded owned block. Everything outside it survives byte-for-byte as UTF-8.
enum CharacterMarkdown {
    static let begin = "<!-- assetframe-character:v1 -->"
    static let end = "<!-- /assetframe-character -->"
    struct Metadata: Codable {
        var version: Int
        var projectID: String
        var characterID: String
        var reviews: [String: CharacterProfile.Review]
        var evidence: [String: String]
        var assets: [CharacterProfile.Asset]
        var stories: [CharacterProfile.Story]
        var sources: [String]
    }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func blockRange(_ text: String) throws -> Range<String.Index>? {
        let starts = text.components(separatedBy: begin).count - 1
        let ends = text.components(separatedBy: end).count - 1
        if starts == 0 && ends == 0 { return nil }
        guard starts == 1, ends == 1, let a = text.range(of: begin), let b = text.range(of: end), a.upperBound < b.lowerBound else {
            throw CharacterLibraryError.invalid("标准档案区块重复或不完整，未覆盖原文")
        }
        return a.lowerBound..<b.upperBound
    }
    static func identity(_ text: String) throws -> (projectID: String, characterID: String)? {
        guard let range = try blockRange(text) else { return nil }
        let block = String(text[range])
        guard let a = block.range(of: "```json\n"), let b = block.range(of: "\n```", range: a.upperBound..<block.endIndex) else { throw CharacterLibraryError.invalid("档案元数据缺失") }
        let meta = try JSONDecoder().decode(Metadata.self, from: Data(block[a.upperBound..<b.lowerBound].utf8))
        return (meta.projectID, meta.characterID)
    }
    static func decode(_ text: String, projectID: String, characterID: String) throws -> CharacterProfile {
        guard let range = try blockRange(text) else {
            var profile = CharacterProfile(projectID: projectID, characterID: characterID)
            let heading = text.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? ""
            profile.fields["姓名"] = .init(text: heading, review: .candidate, evidence: "仅取原文件标题，请核对人物姓名")
            return profile
        }
        let block = String(text[range])
        guard let a = block.range(of: "```json\n"), let b = block.range(of: "\n```", range: a.upperBound..<block.endIndex) else { throw CharacterLibraryError.invalid("档案引用元数据缺失") }
        let meta = try JSONDecoder().decode(Metadata.self, from: Data(block[a.upperBound..<b.lowerBound].utf8))
        guard meta.projectID == projectID, meta.characterID == characterID else { throw CharacterLibraryError.invalid("MD 中的人物或项目 ID 与关联记录不一致") }
        var profile = CharacterProfile(version: meta.version, projectID: projectID, characterID: characterID, assets: meta.assets, stories: meta.stories, sources: meta.sources)
        let fieldsText = String(block[block.startIndex..<a.lowerBound])
        let parts = fieldsText.components(separatedBy: "\n### ")
        for part in parts.dropFirst() {
            guard let newline = part.firstIndex(of: "\n") else { continue }
            let key = String(part[..<newline])
            guard CharacterProfile.fieldNames.contains(key) else { throw CharacterLibraryError.invalid("发现未知标准栏目：\(key)，请先在原文核对") }
            // The final metadata heading is outside every field body.
            let value = String(part[part.index(after: newline)...]).components(separatedBy: "\n## 引用与状态")[0].trimmingCharacters(in: .newlines)
            guard profile.fields[key] == nil else { throw CharacterLibraryError.invalid("标准栏目重复：\(key)") }
            if !value.isEmpty || meta.reviews[key] != nil || meta.evidence[key] != nil {
                profile.fields[key] = .init(text: value, review: meta.reviews[key] ?? .pending, evidence: meta.evidence[key] ?? "")
            }
        }
        try profile.validate()
        return profile
    }
    static func render(_ profile: CharacterProfile, replacing original: String) throws -> String {
        try profile.validate()
        for field in profile.fields.values {
            guard !field.text.contains(begin), !field.text.contains(end), !field.text.contains("\n### "), !field.text.contains("\n## 引用与状态"), !field.text.contains("```json\n") else { throw CharacterLibraryError.invalid("栏目内容包含保留的结构标记，请改用普通文本或四级标题") }
        }
        let meta = Metadata(version: 1, projectID: profile.projectID, characterID: profile.characterID,
                            reviews: profile.fields.mapValues(\.review), evidence: profile.fields.mapValues(\.evidence),
                            assets: profile.assets, stories: profile.stories, sources: profile.sources)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var block = begin + "\n## 人物标准档案\n"
        for key in CharacterProfile.fieldNames { block += "\n### \(key)\n\(profile.fields[key]?.text ?? "")\n" }
        block += "\n## 引用与状态\n```json\n\(String(decoding: try encoder.encode(meta), as: UTF8.self))\n```\n" + end
        if let range = try blockRange(original) { return original.replacingCharacters(in: range, with: block) }
        return original + (original.hasSuffix("\n") || original.isEmpty ? "" : "\n") + "\n" + block + "\n"
    }
    static func read(_ url: URL) throws -> (String, String) {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CharacterLibraryError.missing }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw CharacterLibraryError.invalid("MD 文件超过 4 MiB，请分拆后关联") }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw CharacterLibraryError.invalid("仅支持 4 MiB 以内的 UTF-8 MD 文件") }
        return (text, fingerprint(data))
    }
    /// Coordinated compare-before-write, with a recoverable copy of the exact old bytes.
    static func save(_ text: String, to url: URL, expected: String) throws -> URL {
        var coordinationError: NSError?
        var outcome: Result<URL, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            outcome = Result {
                let old = try Data(contentsOf: coordinated)
                guard fingerprint(old) == expected else { throw CharacterLibraryError.conflict }
                let folder = coordinated.deletingLastPathComponent().appendingPathComponent(".assetframe-character-backups", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let backup = folder.appendingPathComponent(coordinated.lastPathComponent + "." + UUID().uuidString + ".bak")
                try old.write(to: backup, options: .withoutOverwriting)
                // Check again after backup I/O for non-coordinating editors.
                guard fingerprint(try Data(contentsOf: coordinated)) == expected else { throw CharacterLibraryError.conflict }
                try Data(text.utf8).write(to: coordinated, options: .atomic)
                return backup
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CharacterLibraryError.invalid("文件协调失败，草稿未丢弃") }
        return try outcome.get()
    }
}
