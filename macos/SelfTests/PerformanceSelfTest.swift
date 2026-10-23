import Foundation

@main
struct AssetFramePerformanceSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("assetframe-performance-\(UUID().uuidString)", isDirectory: true)
        let assetsURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let sharedImage = assetsURL.appendingPathComponent("基准图片.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: sharedImage)
        let now = Date()
        let assets = (1...5_000).map { index in
            AssetItem(
                id: String(format: "ASSET-%05d", index), name: "资产 \(index)",
                type: index.isMultiple(of: 4) ? .person : index.isMultiple(of: 3) ? .scene : .prop,
                imagePath: sharedImage.path, originalFilename: sharedImage.lastPathComponent,
                decision: index.isMultiple(of: 5) ? .confirmed : .pending, note: "", reuse: .b,
                project: "性能基准", episodes: index.isMultiple(of: 2) ? ["第1集"] : ["第2集"], candidatePlan: .none,
                version: "v01", purpose: .pending, category: index.isMultiple(of: 7) ? .common : .project,
                qaResult: .pending, productionStatus: .pendingAcceptance, assetDescription: "性能基准记录",
                repairReason: "", fingerprint: "", shapeState: "", promptSource: "", generationPlatform: "",
                position: CanvasPoint(x: CGFloat(index % 10) * 220, y: CGFloat(index / 10) * 190), createdAt: now
            )
        }
        let library = LibraryData(assets: assets, groups: [], relations: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: rootURL.appendingPathComponent("library.json"), options: .atomic)

        let coldStart = monotonicTime()
        let store = AssetStore(rootURL: rootURL)
        await waitUntil { !store.isLoadingProject }
        let coldMilliseconds = milliseconds(since: coldStart)
        precondition(store.assets.count == 5_000)

        var checksum = 0
        let switchStart = monotonicTime()
        for index in 0..<2_000 {
            let view: SavedView = index.isMultiple(of: 4) ? .allGallery : index.isMultiple(of: 3) ? .people : index.isMultiple(of: 2) ? .venues : .props
            checksum &+= store.assets(for: view, search: "").count
        }
        let switchMilliseconds = milliseconds(since: switchStart)
        let averageSwitchMilliseconds = switchMilliseconds / 2_000
        precondition(averageSwitchMilliseconds < 200, "缓存后页面切换超过 200ms")

        let searchStart = monotonicTime()
        for _ in 0..<20 { checksum &+= store.assets(for: .allGallery, search: "资产 49").count }
        let searchMilliseconds = milliseconds(since: searchStart)

        let updateStart = monotonicTime()
        store.updateAsset("ASSET-02500") { $0.decision = .confirmed }
        let updateMilliseconds = milliseconds(since: updateStart)
        await store.flushCurrentProject()

        let cleanFlushStart = monotonicTime()
        await store.flushCurrentProject()
        let cleanFlushMilliseconds = milliseconds(since: cleanFlushStart)
        precondition(cleanFlushMilliseconds < 50, "无修改项目仍触发了整库保存")

        let reopenStart = monotonicTime()
        let reopened = AssetStore(rootURL: rootURL)
        await waitUntil { !reopened.isLoadingProject }
        let reopenMilliseconds = milliseconds(since: reopenStart)
        precondition(reopened.assets.count == 5_000)
        precondition(checksum > 0)

        print("5,000-asset benchmark passed")
        print(String(format: "cold migration: %.1f ms", coldMilliseconds))
        print(String(format: "cached view switch average: %.4f ms", averageSwitchMilliseconds))
        print(String(format: "20 repeated searches with cache: %.1f ms", searchMilliseconds))
        print(String(format: "single asset update + derived caches: %.1f ms", updateMilliseconds))
        print(String(format: "clean project flush: %.3f ms", cleanFlushMilliseconds))
        print(String(format: "SQLite reopen: %.1f ms", reopenMilliseconds))
    }

    private static func monotonicTime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for the performance test")
    }
}
