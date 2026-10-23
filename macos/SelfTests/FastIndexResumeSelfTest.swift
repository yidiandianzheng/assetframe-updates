import Foundation

@main
struct FastIndexResumeSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("assetframe-fast-index-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let appData = root.appendingPathComponent("app-data", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        for index in 0..<520 {
            let url = source.appendingPathComponent(String(format: "%04d.png", index))
            try Data([0x89, 0x50, 0x4e, 0x47, UInt8(index % 251)]).write(to: url)
        }

        let store = AssetStore(rootURL: appData)
        await waitUntil { !store.isLoadingProject }
        let startedAt = Date()
        store.stageImages([source])
        await waitUntil { !store.isImporting }
        let elapsed = Date().timeIntervalSince(startedAt)
        precondition(store.pendingImports.count == 520)
        precondition(store.pendingImports.allSatisfy { $0.pixelWidth == nil && $0.pixelHeight == nil }, "大型目录应先完成轻量索引")
        precondition(elapsed < 10, "本地轻量索引不应退化为逐张读图：\(elapsed)s")
        await store.flushPendingImportManifest()

        let journalURL = root.appendingPathComponent("journal.ndjson")
        let writer = PendingImportJournalWriter()
        try await writer.append(Array(store.pendingImports.prefix(3)), to: journalURL)
        try await writer.append(Array(store.pendingImports.dropFirst(3).prefix(2)), to: journalURL)
        precondition(PendingImportJournalWriter.load(from: journalURL).count == 5, "追加式断点必须可恢复")

        let reopened = AssetStore(rootURL: appData)
        await waitUntil { !reopened.isLoadingProject && reopened.pendingImports.count == 520 }
        let repeatStartedAt = Date()
        reopened.stageImages([source])
        await waitUntil { !reopened.isImporting }
        let repeatElapsed = Date().timeIntervalSince(repeatStartedAt)
        precondition(reopened.pendingImports.count == 520, "重新拖入必须跳过已落盘记录并从断点继续")
        precondition(reopened.importProgress?.skipped == 520)
        precondition(repeatElapsed < 10, "重复目录跳过不应被界面进度刷新拖慢：\(repeatElapsed)s")
        print("FastIndexResumeSelfTest passed:first_ms=\(elapsed * 1_000),repeat_ms=\(repeatElapsed * 1_000)")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for fast index")
    }
}
