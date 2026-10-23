import Foundation

@main
struct DuplicateImportQueueSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("assetframe-duplicate-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try fileManager.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let first = firstDirectory.appendingPathComponent("same.png")
        let second = secondDirectory.appendingPathComponent("same.png")
        try png.write(to: first)
        try png.write(to: second)

        let dataRoot = root.appendingPathComponent("AppData", isDirectory: true)
        let store = AssetStore(rootURL: dataRoot)
        await waitUntil("initial load") { !store.isLoadingProject }
        store.stageImages([first])
        await waitUntil("first import") { !store.isImporting && store.pendingImports.count == 1 }
        store.stageImages([second])
        await waitUntil("duplicate queued") { !store.isImporting && store.duplicateImportCandidates.count == 1 }
        store.dismissDuplicateImportMessage()
        precondition(store.duplicateImportCandidates.count == 1, "关闭提示只能暂存，不能清空队列")
        try await Task.sleep(for: .milliseconds(250))

        let reopened = AssetStore(rootURL: dataRoot)
        await waitUntil("queue restored") {
            !reopened.isLoadingProject && reopened.duplicateImportCandidates.count == 1
        }
        let candidate = reopened.duplicateImportCandidates[0]
        precondition(candidate.existingPath == first.path)
        precondition(candidate.incomingPath == second.path)
        reopened.resolveDuplicateImport(candidate.id, decision: .useExisting, applyToAll: false)
        precondition(reopened.duplicateImportCandidates.isEmpty)
        precondition(reopened.pendingImports.count == 1)
        try await Task.sleep(for: .milliseconds(250))

        let finalReload = AssetStore(rootURL: dataRoot)
        await waitUntil("resolved queue remains empty") { !finalReload.isLoadingProject }
        try await Task.sleep(for: .milliseconds(250))
        precondition(finalReload.duplicateImportCandidates.isEmpty)
        precondition(fileManager.fileExists(atPath: first.path))
        precondition(fileManager.fileExists(atPath: second.path), "处理重复项不得删除原文件")
        print("DuplicateImportQueueSelfTest passed")
    }

    @MainActor
    private static func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        precondition(condition(), "等待超时：\(label)")
    }
}
