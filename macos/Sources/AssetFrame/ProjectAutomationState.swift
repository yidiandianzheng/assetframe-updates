import Foundation

/// Local, rebuildable evidence and work queue. Never a source of user confirmation.
struct ProjectAutomationState: Codable, Sendable {
    struct Permission: Codable, Sendable {
        var enabled: Bool
        var endpoint: String
    }
    struct Target: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var kind: String
        var name: String
    }
    struct Field: Codable, Hashable, Sendable {
        var name: String
        var value: String
        var evidence: String
    }
    struct Extraction: Codable, Sendable {
        var name: String
        var kind: String
        var fields: [Field]
        var conflict: String
    }
    struct Job: Codable, Identifiable, Sendable {
        var id: String
        var projectID: String
        var path: String
        var fingerprint: String
        var context: String
        var target: Target?
        var status: String = "待整理"
        var result: Extraction?
        var issue: String = ""
        var active = true
        var approved = false
    }
    struct Association: Codable, Sendable {
        var projectID: String
        var path: String
        var target: Target
    }
    struct Navigation: Codable, Equatable, Sendable {
        var projectID = ""
        var section = "概览"
        var search = ""
        var selectedID = ""
        var episodeID: String?
        var documentPath: String?
        var assetCategory: String?
        var sourceFolder: String?
    }
    struct WritebackDraft: Codable, Identifiable, Sendable {
        var id: String
        var path: String
        var expected: String
        var text: String
    }
    struct AssetDocumentLink: Codable, Sendable {
        var projectID: String
        var target: String
        var kind: String
        var paths: [String]
    }
    var assetDocuments: [String: AssetDocumentLink]?
    static func assetDocumentKey(projectID: String, target: String, kind: String) -> String {
        CharacterMarkdown.fingerprint(Data([projectID, target, kind].joined(separator: "\u{1F}").utf8))
    }
    var pendingWritebacks: [String: [WritebackDraft]]?
    var documentDrafts: [String: WritebackDraft]?
    var haltReason: String?
    var version = 1
    var permissions: [String: Permission] = [:]
    var jobs: [String: Job] = [:]
    var associations: [Association] = []
    var navigation = Navigation()
    static func legacyAssetTarget(_ text: String) -> Target? {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { return nil }
        var fields: [String: String] = [:]
        for line in text[..<end.lowerBound].components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let id = fields["asset_id"], !id.isEmpty, let name = fields["asset_name"], !name.isEmpty, let type = fields["asset_type"],
              let kind = ["场景", "道具", "服装"].first(where: { type.contains($0) }) else { return nil }
        return Target(id: id, kind: kind, name: name)
    }
    static let ruleVersion = 1
    static func jobID(project: String, path: String, fingerprint: String, context: String, target: Target?) -> String {
        CharacterMarkdown.fingerprint(Data([project, path, fingerprint, context, target?.id ?? "?", target?.kind ?? "?", String(ruleVersion)].joined(separator: "\u{1F}").utf8))
    }
    mutating func recoverInterrupted() {
        for id in jobs.keys where jobs[id]?.status == "整理中" {
            jobs[id]?.status = "待重试"; jobs[id]?.issue = "上次请求中断，可能已发生 API 调用；点击重试后继续。"
        }
    }
}

/// Adapter for existing { resourceID: { path, sha256, kind } } project catalogs.
/// A valid checksum establishes file identity, never user confirmation or default use.
struct ProjectCatalogResource: Identifiable, Sendable {
    var id: String
    var path: String
    var kind: String
    var expectedHash: String?
    var status: String
    var source: String
    static func read(documents: [CharacterProjectDocument], root: URL) -> [ProjectCatalogResource] {
        struct Item: Decodable { var path: String; var kind: String; var sha256: String? }
        var result: [ProjectCatalogResource] = []
        for doc in documents where doc.kind == "资产注册表" && doc.path.hasSuffix(".json") {
            guard let entries = try? JSONDecoder().decode([String: Item].self, from: Data(doc.text.utf8)) else { continue }
            for (id, item) in entries.sorted(by: { $0.key < $1.key }) {
                let url = CharacterProjectModules.resolve(item.path, root: URL(fileURLWithPath: doc.sourceRoot ?? root.path))
                let status: String
                if !FileManager.default.fileExists(atPath: url.path) { status = "文件失联" }
                else if let hash = item.sha256, hash.count == 64 {
                    status = (try? CharacterProjectModules.fileHash(url)) == hash ? "指纹一致 · 用途依据另核对" : "指纹已变化"
                } else { status = "缺少原始指纹" }
                result.append(.init(id: id, path: url.path, kind: item.kind, expectedHash: item.sha256, status: status, source: doc.path))
            }
        }
        return result
    }
}
