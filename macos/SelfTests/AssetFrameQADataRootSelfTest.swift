import Foundation

@main
struct AssetFrameQADataRootSelfTest {
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let valid = temporary.appendingPathComponent("assetframe-qa.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: valid) }
        let resolved = try AssetFrameQADataRoot.resolve(environment: [AssetFrameQADataRoot.environmentKey: valid.path])
        precondition(resolved?.path == valid.path)
        precondition(FileManager.default.fileExists(atPath: valid.path))
        precondition(FileManager.default.fileExists(
            atPath: valid.appendingPathComponent(AssetFrameQADataRoot.managedFiveStarDirectoryName, isDirectory: true).path
        ))
        let absent = try AssetFrameQADataRoot.resolve(environment: [:])
        precondition(absent == nil)

        let privateTmp = URL(fileURLWithPath: "/private/tmp/assetframe-qa.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: privateTmp) }
        let privateTmpResolved = try AssetFrameQADataRoot.resolve(environment: [AssetFrameQADataRoot.environmentKey: privateTmp.path])
        precondition(privateTmpResolved?.path == privateTmp.path)

        do {
            _ = try AssetFrameQADataRoot.resolve(environment: [AssetFrameQADataRoot.environmentKey: "/tmp/not-assetframe"])
            preconditionFailure("非 assetframe-qa.* 目录必须被拒绝")
        } catch is AssetFrameQADataRootError {
            // Expected.
        }
        print("AssetFrameQADataRootSelfTest passed")
    }
}
