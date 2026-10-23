import Foundation

@main
struct LibraryAuditSelfTest {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var asset = makeAsset(id: "A1", name: "", type: .unclassified)
        asset.isSourceMissing = true
        asset.preferredOutputResolution = .fourK
        asset.fingerprint = "PROTECTED-FINGERPRINT"
        asset.version = "v07"
        let duplicate = makeAsset(id: "A2", name: "重复资产", type: .person)
        var duplicateTwo = makeAsset(id: "A3", name: "重复资产", type: .person)
        duplicateTwo.decision = .confirmed
        let variant = AssetVariantRecord(
            id: "V1", name: "桑枝 · 战损", coverAssetID: asset.id,
            memberAssetIDs: [asset.id], createdAt: .now, updatedAt: .now,
            keyDifference: ""
        )

        let issues = LibraryAuditAnalyzer.analyze(
            assets: [asset, duplicate, duplicateTwo],
            variants: [variant],
            scopeAssetIDs: []
        )
        let kinds = Set(issues.map(\.kind))
        precondition(kinds.contains(.sourceMissing))
        precondition(kinds.contains(.unclassified))
        precondition(kinds.contains(.emptyName))
        precondition(kinds.contains(.pendingReview))
        precondition(kinds.contains(.fourKNotReady))
        precondition(kinds.contains(.unlockedVariant))
        precondition(kinds.contains(.missingMainImage))
        precondition(kinds.contains(.missingKeyDifference))
        precondition(kinds.contains(.duplicateName))

        let issue = issues.first { $0.assetIDs == [asset.id] && $0.kind == .unclassified }!
        let decoded = try DeepSeekLibraryAuditClient.decode(
            """
            {"items":[
              {"issueID":"\(issue.id)","assetID":"A1","proposedName":"桑枝基础造型","assetType":"人物","tags":["主角"],"summary":"人物基础母版","explanation":"名称与类型可补齐","confidence":0.93},
              {"issueID":"\(issue.id)","assetID":"OTHER","proposedName":"越权","assetType":"道具","tags":[],"summary":null,"explanation":"不得应用","confidence":1.0}
            ]}
            """,
            issuesByID: [issue.id: issue],
            allowedAssetIDs: ["A1"]
        )
        precondition(decoded.count == 2)
        precondition(decoded[0].assetID == "A1" && decoded[0].assetType == .person)
        precondition(decoded[1].assetID == nil && !decoded[1].hasEditableChange)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LibraryData(assets: [asset], groups: [], relations: [])).write(
            to: root.appendingPathComponent("library.json")
        )
        let store = AssetStore(rootURL: root)
        await waitUntil { !store.isLoadingProject }
        store.prepareLibraryAudit(assetIDs: [asset.id], scopeDescription: "测试")
        store.libraryAuditSession?.suggestions = [decoded[0]]
        store.applyLibraryAuditSuggestion(decoded[0].id)
        guard let updated = store.asset(withID: asset.id) else { preconditionFailure("资产丢失") }
        precondition(updated.name == "桑枝基础造型")
        precondition(updated.type == .person)
        precondition(updated.normalizedTags == ["主角"])
        precondition(updated.assetDescription == "人物基础母版")
        precondition(updated.fingerprint == "PROTECTED-FINGERPRINT")
        precondition(updated.version == "v07")
        precondition(updated.imagePath == asset.imagePath)

        print("LibraryAuditSelfTest passed")
    }

    private static func makeAsset(id: String, name: String, type: AssetType) -> AssetItem {
        var asset = PendingImportItem(
            id: id, stagedPath: "/tmp/\(id).png", originalSourcePath: "/tmp/\(id).png",
            originalFilename: "\(id).png", sourceFileID: id, sourceFileSize: 1,
            sourceModifiedAt: nil, pixelWidth: 1024, pixelHeight: 1024,
            suggestedType: type, category: .project, createdAt: .now
        ).previewAsset
        asset.id = id
        asset.name = name
        return asset
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("等待超时")
    }
}
