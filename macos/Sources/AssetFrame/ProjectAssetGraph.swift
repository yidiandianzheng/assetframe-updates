import Foundation

/// Portable production relationships. Character prose stays in its original MD.
struct ProjectAssetGraph: Codable, Equatable, Sendable {
    struct Subject: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString
        var kind: String
        var name: String
        var description = ""
        var sourcePath = ""
    }
    struct Variant: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString
        var subjectID: String
        var name: String
        var stage = ""
        var fixedFeatures = ""
        var costumeIDs: [String] = []
        var propIDs: [String] = []
    }
    struct Asset: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString
        var subjectID: String
        var variantID: String
        var materialID: String
        var path: String
        var sha256: String
        var role: String
        var stage: String
        var status = "候选"
        var isDefault = false
        var evidence = ""
        var originalPrompt = ""
        var reuseTemplate = ""
        var platform = ""
        var model = ""
        var referencePaths: [String] = []
        var createdAt = Date()
    }
    struct Shot: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString
        var episode: String
        var scene: String
        var name: String
        var sourcePath: String
        var sourceFingerprint: String
    }
    struct Event: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString
        var assetID: String
        var action: String
        var evidence: String
        var date = Date()
    }
    var version = 1
    var projectID: String
    var subjects: [Subject] = []
    var variants: [Variant] = []
    var assets: [Asset] = []
    var shots: [Shot] = []
    var events: [Event] = []
    static let kinds = ["人物", "场景", "道具", "服装"]
    static let marker = "assetframe-production"
    static func url(root: URL) -> URL { root.appendingPathComponent("人物库索引/项目资产与引用.md") }
    func validate(characterIDs: Set<String>) throws {
        func unique(_ ids: [String]) -> Bool { ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count }
        let subjectIDs = Set(subjects.map(\.id)).union(characterIDs)
        guard version == 1, !projectID.isEmpty, unique(subjects.map(\.id)), unique(variants.map(\.id)), unique(assets.map(\.id)), unique(shots.map(\.id)), unique(events.map(\.id)), Set(subjects.map(\.id)).isDisjoint(with: characterIDs), subjects.allSatisfy({ ["场景", "道具", "服装"].contains($0.kind) && !$0.name.isEmpty }) else { throw CharacterLibraryError.invalid("项目资产身份重复、类型或版本不支持") }
        for variant in variants {
            guard subjectIDs.contains(variant.subjectID), !variant.name.isEmpty,
                  variant.costumeIDs.allSatisfy({ id in subjects.contains { $0.id == id && $0.kind == "服装" } }),
                  variant.propIDs.allSatisfy({ id in subjects.contains { $0.id == id && $0.kind == "道具" } }) else { throw CharacterLibraryError.invalid("造型引用了未知主体、服装或道具") }
        }
        var defaults = Set<String>()
        for asset in assets {
            guard variants.contains(where: { $0.id == asset.variantID && $0.subjectID == asset.subjectID }), !asset.path.isEmpty, !asset.materialID.isEmpty, !asset.role.isEmpty, asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit }), CharacterProfile.Asset.statuses.contains(asset.status), asset.status != "已确认" || !asset.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CharacterLibraryError.invalid("资产版本缺少身份、指纹、用途或确认依据") }
            if asset.isDefault {
                guard asset.status == "已确认", defaults.insert([asset.subjectID, asset.stage, asset.role].joined(separator: "\u{1F}")).inserted else { throw CharacterLibraryError.invalid("同一主体、阶段和用途只能有一个已确认默认版本") }
            }
        }
        guard shots.allSatisfy({ !$0.name.isEmpty && ($0.sourcePath.isEmpty ? $0.sourceFingerprint.isEmpty : $0.sourceFingerprint.count == 64) }), events.allSatisfy({ event in assets.contains { $0.id == event.assetID } }) else { throw CharacterLibraryError.invalid("镜头来源或变更记录无效") }
    }
    mutating func setDefault(_ id: String) throws {
        guard let chosen = assets.first(where: { $0.id == id && $0.status == "已确认" }) else { throw CharacterLibraryError.invalid("仅已确认版本可设为默认") }
        for i in assets.indices where assets[i].subjectID == chosen.subjectID && assets[i].stage == chosen.stage && assets[i].role == chosen.role { assets[i].isDefault = assets[i].id == id }
        events.append(.init(assetID: id, action: "设为当前默认", evidence: "用户明确操作；已有镜头引用保持原版本"))
    }
    static func read(root: URL, projectID: String) throws -> (ProjectAssetGraph, String?) {
        let path = url(root: root)
        guard FileManager.default.fileExists(atPath: path.path) else { return (ProjectAssetGraph(projectID: projectID), nil) }
        let (text, hash) = try CharacterMarkdown.read(path)
        let graph = try CharacterProjectModules.decode(Self.self, text: text, marker: marker)
        guard graph.projectID == projectID else { throw CharacterLibraryError.invalid("项目资产记录属于其他项目") }
        return (graph, hash)
    }
    static func save(_ graph: ProjectAssetGraph, root: URL, expected: String?, characterIDs: Set<String>) throws {
        try graph.validate(characterIDs: characterIDs)
        let url = url(root: root)
        let previous = try read(root: root, projectID: graph.projectID)
        guard previous.1 == expected else { throw CharacterLibraryError.conflict }
        for asset in graph.assets where asset.status == "已确认" {
            if previous.0.assets.first(where: { $0.id == asset.id }) != asset { try verify(asset, root: root) }
        }
        let block = try CharacterProjectModules.encode(graph, marker: marker, title: "项目资产与制作引用")
        if let expected {
            let (original, actual) = try CharacterMarkdown.read(url)
            guard actual == expected, let start = original.range(of: "<!-- \(marker):v1 -->"), let end = original.range(of: "<!-- /\(marker) -->"), let a = block.range(of: "<!-- \(marker):v1 -->"), let b = block.range(of: "<!-- /\(marker) -->") else { throw CharacterLibraryError.conflict }
            let merged = String(original[..<start.lowerBound]) + String(block[a.lowerBound..<b.upperBound]) + String(original[end.upperBound...])
            _ = try CharacterMarkdown.save(merged, to: url, expected: expected)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(block.utf8).write(to: url, options: .withoutOverwriting)
        }
    }
    static func verify(_ asset: Asset, root: URL) throws {
        guard try CharacterProjectModules.fileHash(CharacterProjectModules.resolve(asset.path, root: root)) == asset.sha256 else { throw CharacterLibraryError.invalid("素材与确认指纹不同，请作为新版本导入") }
    }
}
