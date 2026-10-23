import Foundation

@main
struct OriginalPlaceScanSafetySelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: workspace)
        }

        let source = workspace.appendingPathComponent("原位素材.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x01]).write(to: source)
        let registry = ProjectRegistry(
            rootURL: root,
            legacyAssetsURL: root.appendingPathComponent("Assets", isDirectory: true)
        )
        let project = registry.addProject(folderURL: workspace)

        let store = AssetStore(rootURL: root)
        await waitUntil { !store.isLoadingProject }
        precondition(store.currentProject.id == project.id)
        precondition(store.pendingImports.isEmpty, "打开空项目不得自动扫描整个工作区")
        let legacyPending = workspace.appendingPathComponent("00_向量时刻待导入", isDirectory: true)
        precondition(!fileManager.fileExists(atPath: legacyPending.path), "打开项目不得重建旧待导入目录")

        store.scanCurrentFolderForNewImages()
        await waitUntil { !store.isImporting && store.pendingImports.count == 1 }
        let pending = store.pendingImports[0]
        precondition(pending.stagedPath == source.path, "显式扫描必须原位引用，不得复制")
        precondition(fileManager.fileExists(atPath: source.path))
        precondition(!fileManager.fileExists(atPath: legacyPending.path), "显式扫描也不得重建项目根目录待导入副本区")
        precondition(
            fileManager.fileExists(atPath: store.pendingImportDirectoryURL.appendingPathComponent(".assetframe-pending.json").path),
            "待确认清单应保存在 Application Support"
        )

        let reopened = AssetStore(rootURL: root)
        let revisionBeforePendingRestore = reopened.contentRevision
        await waitUntil { reopened.pendingImports.count == 1 }
        precondition(
            reopened.contentRevision > revisionBeforePendingRestore,
            "启动后恢复待确认清单必须刷新画册内容版本"
        )

        print("OriginalPlaceScanSafetySelfTest passed")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for original-place scan")
    }
}
