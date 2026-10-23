import Foundation

@main
struct FirstLaunchSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default

        let emptyRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: emptyRoot) }

        let emptyStore = AssetStore(rootURL: emptyRoot)
        await waitUntil { !emptyStore.isLoadingProject }
        precondition(emptyStore.currentProject.name == "资产库")
        precondition(!emptyStore.currentProject.isLegacy)
        precondition(emptyStore.assets.isEmpty, "全新数据根不得生成演示资产")
        precondition(emptyStore.pendingImports.isEmpty)
        precondition(emptyStore.assets.contains(where: { $0.id == "CHAR-001" }) == false)
        try? await Task.sleep(for: .milliseconds(200))
        precondition(emptyStore.localFolders.isEmpty, "全新空库不得把内部 Assets 目录伪装成用户已链接的文件夹")

        let legacyRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: legacyRoot) }
        let legacyAsset = AssetItem(
            id: "LEGACY-1", name: "旧资产", type: .person, imagePath: "", originalFilename: "old.png",
            decision: .confirmed, note: "", reuse: .b, project: "", episodes: [], candidatePlan: .none,
            version: "v01", purpose: .pending, category: .project, qaResult: .pending,
            productionStatus: .pendingAcceptance, assetDescription: "", repairReason: "", fingerprint: "",
            shapeState: "", promptSource: "", generationPlatform: "", position: CanvasPoint(x: 0, y: 0),
            createdAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LibraryData(assets: [legacyAsset], groups: [], relations: []))
            .write(to: legacyRoot.appendingPathComponent("library.json"))

        let legacyStore = AssetStore(rootURL: legacyRoot)
        await waitUntil { !legacyStore.isLoadingProject }
        precondition(legacyStore.currentProject.name == "旧资料库", "真实旧 JSON 仍应按迁移语义标记")
        precondition(legacyStore.currentProject.isLegacy)
        precondition(legacyStore.assets.map(\.id) == ["LEGACY-1"], "移除演示数据不得破坏旧资料迁移")

        print("FirstLaunchSelfTest passed")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out")
    }
}
