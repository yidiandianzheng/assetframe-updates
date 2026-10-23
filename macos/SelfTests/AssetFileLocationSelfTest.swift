import Foundation

@main
struct AssetFileLocationSelfTest {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("assetframe-location-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let original = root.appendingPathComponent("Downloads/source.png")
        let managed = root.appendingPathComponent("Library/managed.png")
        try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        try Data("managed".utf8).write(to: managed)

        let asset = makeAsset(imagePath: managed.path, importSourcePath: original.path)
        precondition(AssetFileLocationResolver.location(for: asset)?.path == managed.path)
        precondition(AssetFileLocationResolver.location(for: asset)?.exists == true)

        try fileManager.removeItem(at: original)
        precondition(AssetFileLocationResolver.location(for: asset)?.exists == true)
        precondition(
            AssetFileLocationResolver.canonicalMaterialPath(primary: original.path, alternatives: [managed.path]) == managed.path,
            "Thumbnail paths must use an existing legacy fallback"
        )

        var legacy = asset
        legacy.importSourcePath = nil
        precondition(AssetFileLocationResolver.location(for: legacy)?.path == managed.path)
        print("AssetFileLocationSelfTest passed")
    }

    private static func makeAsset(imagePath: String, importSourcePath: String?) -> AssetItem {
        AssetItem(
            id: "A-1", name: "测试素材", type: .prop, imagePath: imagePath, originalFilename: "source.png",
            decision: .pending, note: "", reuse: .b, project: "测试", episodes: [], candidatePlan: .none,
            version: "v01", purpose: .propSingle, category: .project, qaResult: .pending,
            productionStatus: .pendingConfirm, assetDescription: "", repairReason: "", fingerprint: "",
            shapeState: "", promptSource: "", generationPlatform: "", position: CanvasPoint(x: 0, y: 0),
            createdAt: .now, importSourcePath: importSourcePath
        )
    }
}
