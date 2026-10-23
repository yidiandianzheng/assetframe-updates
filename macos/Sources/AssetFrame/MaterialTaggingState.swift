import Foundation
import CryptoKit

/// Library-owned metadata. Neither project Markdown nor source images are rewritten.
struct MaterialTaggingState: Codable, Hashable, Sendable {
    struct Term: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var dimension: String = ""
        var aliases: [String] = []
        var scope: String = "通用"
        var favorite = false
        var enabled = true
        var builtin = false
    }
    struct Source: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var path: String
        var scope: String? = nil
    }
    struct Binding: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var materialID: String
        var documentPath: String
        var kind: String = "一般参考资料"
        var excerpt: String? = nil
    }
    struct Evidence: Codable, Hashable, Sendable {
        var kind: String
        var path: String = ""
        var excerpt: String = ""
        var digest: String = ""
    }
    struct Proposal: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var materialID: String
        var inputKey: String
        var baseInputKey: String? = nil
        var imagePath: String
        var imageDigest: String
        var catalogKey: String
        var relationKey: String
        var tags: [String] = []
        var removeTags: [String] = []
        var categories: MaterialClassification = .init()
        var removeCategories: MaterialClassification? = nil
        var evidence: [Evidence] = []
        var uncertainties: [String] = []
        var status: String = "待确认"
        var error: String = ""
        var createdAt: Date = .now
        var decidedAt: Date? = nil
        var engine: String = "本机"
        var hasConflict = false
        var missingDocuments = false
    }
    struct Job: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var materialIDs: [String]
        var completed: [String] = []
        var failed: [String] = []
        var status = "已暂停"
        var forceRetry: Bool? = nil
        var createdAt: Date = .now
    }
    var terms: [Term] = []
    var sources: [Source] = []
    var bindings: [Binding] = []
    var proposals: [Proposal] = []
    var jobs: [Job] = []

    var isEmpty: Bool { terms.isEmpty && sources.isEmpty && bindings.isEmpty && proposals.isEmpty && jobs.isEmpty }
    static func encodedDigest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest((try? encoder.encode(value)) ?? Data())
    }

    static var initialTerms: [Term] {
        ClassificationVocabulary.terms.map {
            Term(id: $0.id, name: $0.canonical, dimension: $0.dimension,
                 aliases: $0.aliases, scope: $0.scope, builtin: true)
        }
    }
    var effectiveTerms: [Term] { terms.isEmpty ? Self.initialTerms : terms }
    var catalogKey: String {
        Self.encodedDigest(effectiveTerms.map { term in var value = term; value.favorite = false; value.aliases = Array(Set(value.aliases)).sorted(); return value }.sorted { $0.id < $1.id })
    }
    var relationKey: String {
        Self.encodedDigest(Relations(sources: sources.sorted { $0.id < $1.id }, bindings: bindings.sorted { $0.id < $1.id }))
    }
    private struct Relations: Encodable { var sources: [Source]; var bindings: [Binding] }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fileDigest(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func linkDigest(_ links: [ProjectMaterialLink]) -> String { encodedDigest(links.sorted { $0.id < $1.id }) }
    static func directoryDigest(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var rows: [String] = []
        for case let url as URL in walker {
            try Task.checkCancellation()
            if ["node_modules", ".build", "开发缓存", "rollback", "历史资料"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard ["md", "markdown", "txt", "json"].contains(url.pathExtension.lowercased()) else { continue }
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard info.isRegularFile == true else { continue }
            rows.append(url.standardizedFileURL.path + "|\(info.fileSize ?? -1)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return digest(Data(rows.sorted().joined(separator: "\n").utf8))
    }
    func term(_ name: String, dimension: String? = nil) -> Term? {
        effectiveTerms.first { $0.enabled && (dimension == nil || $0.dimension == dimension) &&
            ($0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) }
    }
    func isCurrent(_ proposal: Proposal, material: MaterialRecord, links: [ProjectMaterialLink]? = nil, digests: [String: String]? = nil) -> Bool {
        guard material.deletedAt == nil, material.sourcePath == proposal.imagePath,
              catalogKey == proposal.catalogKey, relationKey == proposal.relationKey,
              (digests.map { $0[proposal.imagePath] } ?? (try? Self.fileDigest(proposal.imagePath))) == proposal.imageDigest else { return false }
        for item in proposal.evidence where !item.path.isEmpty && !item.digest.isEmpty {
            let current = digests.map { $0[item.path] } ?? (item.kind == "资料目录清单" ? (try? Self.directoryDigest(item.path)) : (try? Self.fileDigest(item.path)))
            guard current == item.digest else { return false }
        }
        // Embedded prompts and explicit material links also participate in input invalidation.
        for item in proposal.evidence where item.kind == "素材生成提示词" {
            guard Self.digest(Data((material.production?.prompt ?? "").utf8)) == item.digest else { return false }
        }
        if let links, let stamp = proposal.evidence.first(where: { $0.kind == "素材关联快照" }) {
            guard Self.linkDigest(links.filter { $0.materialID == material.id }) == stamp.digest else { return false }
        }
        return true
    }
    static func staleIDs(_ proposals: [Proposal], state: Self, records: [MaterialRecord], links: [ProjectMaterialLink]) throws -> Set<String> {
        let records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var digests: [String: String] = [:]
        let directories = Set(proposals.flatMap(\.evidence).filter { $0.kind == "资料目录清单" }.map(\.path))
        let paths = Set(proposals.map(\.imagePath) + proposals.flatMap(\.evidence).filter { !$0.path.isEmpty && !$0.digest.isEmpty }.map(\.path))
        for path in paths {
            try Task.checkCancellation()
            digests[path] = directories.contains(path) ? (try? directoryDigest(path)) : (try? fileDigest(path))
        }
        let byMaterial = Dictionary(grouping: links, by: \.materialID)
        return Set(proposals.filter { proposal in
            guard let record = records[proposal.materialID] else { return true }
            return !state.isCurrent(proposal, material: record, links: byMaterial[record.id] ?? [], digests: digests)
        }.map(\.id))
    }
    static func conflicts(_ proposal: Proposal, with record: MaterialRecord) -> Bool {
        !proposal.removeTags.isEmpty || (proposal.removeCategories?.groups.contains { group in
            !Set(record.classification?.terms(for: group.dimension) ?? []).isDisjoint(with: group.terms)
        } ?? false) || proposal.categories.groups.contains { group in
            !ClassificationVocabulary.allowsMultiple(group.dimension) &&
            !(record.classification?.terms(for: group.dimension) ?? []).isEmpty &&
            Set(record.classification?.terms(for: group.dimension) ?? []) != Set(group.terms)
        }
    }
}
