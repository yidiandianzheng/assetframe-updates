import Foundation
import CryptoKit

/// Portable project files: index contains references, profiles contain persona text,
/// receipts contain immutable generation/confirmation facts. No second persona database.
enum CharacterProjectModules {
    static let directory = "人物库索引"
    struct Reference: Codable, Equatable, Identifiable, Sendable {
        var characterID: String
        var kind: String
        var path: String
        var fingerprint: String
        var id: String { characterID + "|" + kind + "|" + path }
    }
    struct Index: Codable, Equatable, Sendable {
        var version = 1
        var projectID: String
        var references: [Reference] = []
    }
    struct Receipt: Codable, Equatable, Sendable {
        var version = 1
        var id = UUID().uuidString
        var projectID: String
        var characterID: String
        var assetPath: String
        var sha256: String
        var materialID: String?
        var variant: String
        var role: String
        var stage: String
        var status = "已确认"
        var confirmationEvidence: String
        var confirmedAt: String = ISO8601DateFormatter().string(from: Date())
        var platform: String
        var model: String
        var originalPrompt: String
        var normalizedPrompt: [String: String]
        var profilePath: String
        var sourcePaths: [String]
        func validate() throws {
            guard version == 1, !projectID.isEmpty, !characterID.isEmpty, !id.isEmpty,
                  !assetPath.isEmpty, sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }),
                  CharacterProfile.Asset.roles.contains(role), CharacterProfile.Asset.statuses.contains(status),
                  !confirmationEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !profilePath.isEmpty, ISO8601DateFormatter().date(from: confirmedAt) != nil, normalizedPrompt.keys.allSatisfy({ CharacterProfile.groups[2].1.contains($0) }) else {
                throw CharacterLibraryError.invalid("确认记录缺少身份、资产指纹、确认依据，或提示词栏目无效")
            }
        }
    }
    static func resolve(_ path: String, root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    static func relative(_ url: URL, root: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
    static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func encode<T: Encodable>(_ value: T, marker: String, title: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        return "# \(title)\n\n标准记录以以下区块为准；文件路径可相对于项目根目录。缺失信息留空，不代表已确认。\n\n<!-- \(marker):v1 -->\n```json\n\(json)\n```\n<!-- /\(marker) -->\n"
    }
    static func decode<T: Decodable>(_ type: T.Type, text: String, marker: String) throws -> T {
        let start = "<!-- \(marker):v1 -->", end = "<!-- /\(marker) -->"
        guard text.components(separatedBy: start).count == 2, text.components(separatedBy: end).count == 2,
              let a = text.range(of: start), let b = text.range(of: end), a.upperBound < b.lowerBound,
              let x = text.range(of: "```json\n", range: a.upperBound..<b.lowerBound),
              let y = text.range(of: "\n```", range: x.upperBound..<b.lowerBound) else {
            throw CharacterLibraryError.invalid("模块标准区块重复、缺失或损坏")
        }
        return try JSONDecoder().decode(type, from: Data(text[x.upperBound..<y.lowerBound].utf8))
    }
    static func indexURL(root: URL) -> URL { root.appendingPathComponent(directory + "/索引.md") }
    static func readIndex(root: URL, projectID: String) throws -> (Index, String?) {
        let url = indexURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return (Index(projectID: projectID), nil) }
        let (text, hash) = try CharacterMarkdown.read(url)
        let value = try decode(Index.self, text: text, marker: "assetframe-project-index")
        guard value.version == 1, value.projectID == projectID, Set(value.references.map(\.id)).count == value.references.count else {
            throw CharacterLibraryError.invalid("项目索引身份或引用冲突，未覆盖")
        }
        return (value, hash)
    }
    static func writeIndex(_ index: Index, root: URL, expected: String?) throws {
        let url = indexURL(root: root)
        try prepareDirectory(root: root)
        let text = try encode(index, marker: "assetframe-project-index", title: "项目人物模块索引")
        if let expected {
            let original = try CharacterMarkdown.read(url).0
            let start = "<!-- assetframe-project-index:v1 -->", end = "<!-- /assetframe-project-index -->"
            guard let a = original.range(of: start), let b = original.range(of: end), a.upperBound < b.lowerBound,
                  let x = text.range(of: start), let y = text.range(of: end) else { throw CharacterLibraryError.invalid("项目索引区块损坏") }
            _ = try decode(Index.self, text: original, marker: "assetframe-project-index")
            let merged = original.replacingCharacters(in: a.lowerBound..<b.upperBound, with: text[x.lowerBound..<y.upperBound])
            _ = try CharacterMarkdown.save(merged, to: url, expected: expected)
        }
        else { try Data(text.utf8).write(to: url, options: .withoutOverwriting) }
    }
    static func prepareDirectory(root: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw CharacterLibraryError.missing }
        let target = root.appendingPathComponent(directory)
        let real = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard real.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw CharacterLibraryError.invalid("人物索引目录指向项目外，未写入")
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
    }
    static func receiptURL(_ receipt: Receipt, root: URL) -> URL {
        // File name derives from a digest, never user text or externally supplied IDs.
        let key = CharacterMarkdown.fingerprint(Data((receipt.projectID + "|" + receipt.id).utf8))
        return root.appendingPathComponent(directory + "/确认记录-" + key.prefix(24) + ".md")
    }
    static func saveReceipt(_ receipt: Receipt, root: URL) throws -> URL {
        try receipt.validate(); try prepareDirectory(root: root)
        let url = receiptURL(receipt, root: root)
        let data = Data(try encode(receipt, marker: "assetframe-confirmation", title: "资产确认与生成记录").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw CharacterLibraryError.conflict }
        } else { try data.write(to: url, options: .withoutOverwriting) }
        return url
    }
    static func verify(_ receipt: Receipt, root: URL, projectID: String) throws {
        try receipt.validate()
        guard receipt.projectID == projectID else { throw CharacterLibraryError.invalid("确认记录属于其他项目") }
        let profileText = try CharacterMarkdown.read(resolve(receipt.profilePath, root: root)).0
        guard let identity = try CharacterMarkdown.identity(profileText), identity.projectID == receipt.projectID,
              identity.characterID == receipt.characterID else { throw CharacterLibraryError.invalid("确认记录的人物档案身份不匹配") }
        guard try fileHash(resolve(receipt.assetPath, root: root)) == receipt.sha256 else {
            throw CharacterLibraryError.invalid("资产内容与确认时不一致，请重新核对；未沿用确认")
        }
    }
    static func upsert(_ references: [Reference], into index: Index) -> Index {
        var result = index
        for reference in references {
            result.references.removeAll { $0.id == reference.id }; result.references.append(reference)
        }
        result.references.sort { $0.id < $1.id }; return result
    }
}
