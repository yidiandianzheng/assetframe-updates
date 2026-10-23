import Foundation

@main
struct LocalFolderImportSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importedRoot = root.appendingPathComponent("西方领主游戏", isDirectory: true)
        let portraitFolder = importedRoot.appendingPathComponent("人物/顾长宁/四视图", isDirectory: true)
        let posterFolder = importedRoot.appendingPathComponent("海报构图", isDirectory: true)
        let emptyFolder = importedRoot.appendingPathComponent("场景/空目录", isDirectory: true)
        try fileManager.createDirectory(at: portraitFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: posterFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: portraitFolder.appendingPathComponent("正面.png"))
        defer { try? fileManager.removeItem(at: root) }

        let store = AssetStore(rootURL: root.appendingPathComponent("AppData", isDirectory: true))
        await waitUntil("initial project load") { !store.isLoadingProject }
        let initialAssetCount = store.assets.count
        store.importLocalFolder(importedRoot)
        await waitUntil(
            "first linked folder import",
            diagnostics: {
                "isImporting=\(store.isImporting), localFolders=\(store.localFolders.count), pendingImports=\(store.pendingImports.count), progress=\(String(describing: store.importProgress))"
            }
        ) { !store.isImporting && store.localFolders.count == 1 }

        let source = try require(store.localFolders.first, "应保存导入的本地文件夹根")
        precondition(source.rootPath == importedRoot.standardizedFileURL.path)
        precondition(source.directoryPaths.contains("人物"))
        precondition(source.directoryPaths.contains("人物/顾长宁"))
        precondition(source.directoryPaths.contains("人物/顾长宁/四视图"))
        precondition(source.directoryPaths.contains("海报构图"))
        precondition(source.directoryPaths.contains("场景/空目录"), "空目录也必须进入镜像树")

        let pending = try require(store.pendingImports.first, "子目录图片应进入待导入区")
        precondition(pending.sourceFolderID == source.id)
        precondition(pending.sourceRelativePath == "人物/顾长宁/四视图/正面.png")
        precondition(pending.originalSourcePath == portraitFolder.appendingPathComponent("正面.png").path)
        precondition(pending.stagedPath == pending.originalSourcePath, "原位管理不得创建待导入副本")
        precondition(pending.suggestedType == .person, "应结合原文件夹路径自动识别人物资产")
        precondition(pending.filenameClassificationEvidence?.contains("人物") == true)
        precondition(
            store.assets(
                inLocalFolder: source.id,
                relativePath: "人物/顾长宁",
                search: "",
                filter: AssetFilter(),
                sort: .newest
            ).map(\.id) == [pending.previewAsset.id],
            "待确认图片也必须立即出现在本地目录浏览中"
        )
        precondition(store.localFolderAssetCount(source.id, relativePath: "") == 1)
        precondition(store.localFolderAssetCount(source.id, relativePath: "场景") == 0)

        let originalPendingURL = portraitFolder.appendingPathComponent("正面.png")
        let movedPendingURL = posterFolder.appendingPathComponent("正面.png")
        store.moveGalleryAssets(
            [pending.previewAsset.id],
            fromProjectID: store.currentProject.id,
            toLocalFolder: source.id,
            relativePath: "海报构图"
        )
        await waitUntil("pending asset move") { store.pendingImport(withID: pending.id)?.stagedPath == movedPendingURL.path }
        precondition(!fileManager.fileExists(atPath: originalPendingURL.path), "拖拽分类必须移动原文件，而不是复制")
        precondition(fileManager.fileExists(atPath: movedPendingURL.path))
        precondition(store.pendingImport(withID: pending.id)?.sourceRelativePath == "海报构图/正面.png")
        precondition(store.localFolderAssetCount(source.id, relativePath: "海报构图") == 1)
        precondition(store.localFolderAssetCount(source.id, relativePath: "人物/顾长宁") == 0)

        store.confirmPendingImports([pending.id])
        await waitUntil("pending confirmation") {
            !store.isImporting && store.pendingImports.isEmpty && store.assets.count == initialAssetCount + 1
        }
        let asset = try require(
            store.assets.first(where: { $0.sourceFolderID == source.id }),
            "确认后应进入正式资产库"
        )
        precondition(asset.sourceFolderID == source.id)
        precondition(asset.sourceOriginalPath == movedPendingURL.path)
        precondition(asset.sourceRelativePath == "海报构图/正面.png")
        precondition(asset.imagePath == movedPendingURL.path, "确认入库后必须继续引用已移动的原文件")
        precondition(
            store.assets(
                inLocalFolder: source.id,
                relativePath: "海报构图",
                search: "",
                filter: AssetFilter(),
                sort: .newest
            ).map(\.id) == [asset.id],
            "拖入目标目录后应立即按新目录显示"
        )

        let collision = portraitFolder.appendingPathComponent("正面.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x7F]).write(to: collision)
        let movedConfirmedURL = portraitFolder.appendingPathComponent("正面 2.png")
        store.moveGalleryAssets(
            [asset.id],
            fromProjectID: store.currentProject.id,
            toLocalFolder: source.id,
            relativePath: "人物/顾长宁/四视图"
        )
        await waitUntil("confirmed asset move") { store.asset(withID: asset.id)?.imagePath == movedConfirmedURL.path }
        precondition(!fileManager.fileExists(atPath: movedPendingURL.path))
        precondition(fileManager.fileExists(atPath: collision.path), "同名文件不得被覆盖")
        precondition(fileManager.fileExists(atPath: movedConfirmedURL.path), "同名冲突应生成唯一文件名")
        precondition(store.asset(withID: asset.id)?.sourceOriginalPath == movedConfirmedURL.path)
        precondition(store.asset(withID: asset.id)?.sourceRelativePath == "人物/顾长宁/四视图/正面 2.png")

        let renamedRelativeFolder = try require(
            store.renameLocalFolder(
                source.id,
                relativePath: "人物/顾长宁/四视图",
                to: "四视图精选"
            ),
            "子文件夹应能直接重命名"
        )
        precondition(renamedRelativeFolder == "人物/顾长宁/四视图精选")
        let renamedFolderURL = importedRoot.appendingPathComponent(renamedRelativeFolder, isDirectory: true)
        let folderRenamedAssetURL = renamedFolderURL.appendingPathComponent("正面 2.png")
        precondition(!fileManager.fileExists(atPath: portraitFolder.path), "旧文件夹名不应继续存在")
        precondition(fileManager.fileExists(atPath: renamedFolderURL.path))
        precondition(store.asset(withID: asset.id)?.imagePath == folderRenamedAssetURL.path)
        precondition(store.asset(withID: asset.id)?.sourceRelativePath == "人物/顾长宁/四视图精选/正面 2.png")

        let renamedOriginalPath = try require(
            store.renameOriginalFile(for: asset.id, toBaseName: "顾长宁正面"),
            "正式资产原文件应能重命名"
        )
        let renamedOriginalURL = renamedFolderURL.appendingPathComponent("顾长宁正面.png")
        precondition(renamedOriginalPath == renamedOriginalURL.path)
        precondition(!fileManager.fileExists(atPath: folderRenamedAssetURL.path))
        precondition(fileManager.fileExists(atPath: renamedOriginalURL.path))
        precondition(store.asset(withID: asset.id)?.imagePath == renamedOriginalURL.path)
        precondition(store.asset(withID: asset.id)?.sourceOriginalPath == renamedOriginalURL.path)
        precondition(store.asset(withID: asset.id)?.originalFilename == "顾长宁正面.png")
        precondition(store.asset(withID: asset.id)?.sourceRelativePath == "人物/顾长宁/四视图精选/顾长宁正面.png")

        let duplicateFolder = importedRoot.appendingPathComponent("重复候选", isDirectory: true)
        try fileManager.createDirectory(at: duplicateFolder, withIntermediateDirectories: true)
        let duplicate = duplicateFolder.appendingPathComponent("正面副本.png")
        try fileManager.copyItem(at: renamedOriginalURL, to: duplicate)
        store.stageImages([duplicate])
        await waitUntil("duplicate scan") { !store.isImporting }
        await store.waitForBackgroundMetadata()
        precondition(store.pendingImports.count == 1, "内容重复先登记，后台提示处理")
        precondition(
            Set(store.duplicateImportPaths) == [duplicate.path, renamedOriginalURL.path],
            "重复对比应同时保留新文件与已登记文件的位置"
        )
        precondition(store.duplicateImportMessage?.contains("发现 1 组内容完全相同") == true)
        precondition(fileManager.fileExists(atPath: duplicate.path), "重复检测只提醒，不得删除原文件")

        await store.flushCurrentProject()
        let snapshot = try await ProjectDatabase(url: URL(fileURLWithPath: store.currentProject.databasePath)).load()
        let restored = try require(snapshot.localFolders.first, "本地目录树必须跟随项目数据库持久化")
        let currentSource = try require(store.localFolders.first(where: { $0.id == source.id }), "重命名后本地文件夹索引必须存在")
        precondition(restored.id == source.id)
        precondition(restored.rootPath == source.rootPath)
        precondition(restored.directoryPaths == currentSource.directoryPaths)

        store.removeLocalFolder(source.id)
        precondition(fileManager.fileExists(atPath: importedRoot.path), "移除索引不得删除本地文件夹")

        let linkedProjectRoot = root.appendingPathComponent("LinkedHost/西方领主游戏", isDirectory: true)
        let fakeVolumePrefix = root.appendingPathComponent("FakeVolumes", isDirectory: true)
        let linkedSSDProject = fakeVolumePrefix.appendingPathComponent("SSD-1TB/西方领主游戏", isDirectory: true)
        let linkedSSDAssets = linkedSSDProject.appendingPathComponent("03_美术资产", isDirectory: true)
        try fileManager.createDirectory(at: linkedProjectRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: linkedSSDAssets, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: linkedProjectRoot.appendingPathComponent("03_美术资产", isDirectory: true),
            withDestinationURL: linkedSSDAssets
        )
        let linkedRoots = AssetStore.externalLinkedProjectRoots(
            at: linkedProjectRoot,
            projectName: "西方领主游戏",
            externalVolumePrefix: fakeVolumePrefix.path + "/"
        )
        precondition(linkedRoots.map(\.standardizedFileURL.path) == [linkedSSDProject.standardizedFileURL.path])

        let ssdSource = LocalFolderSource(
            id: "SSD-SOURCE",
            name: "西方领主游戏",
            rootPath: "/Volumes/SSD-1TB/西方领主游戏",
            bookmarkData: nil,
            directoryPaths: [""],
            createdAt: .now,
            lastScannedAt: nil
        )
        precondition(ssdSource.sidebarDisplayName == "西方领主游戏 · SSD")
        var localSource = ssdSource
        localSource.rootPath = "/Users/test/西方领主游戏"
        precondition(localSource.sidebarDisplayName == "西方领主游戏")

        let aggregateRoot = root.appendingPathComponent("Aggregate", isDirectory: true)
        let aggregateLocal = aggregateRoot.appendingPathComponent("西方领主游戏", isDirectory: true)
        let aggregateSSD = aggregateRoot.appendingPathComponent("西方领主游戏 · SSD", isDirectory: true)
        try fileManager.createDirectory(at: aggregateLocal, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: aggregateSSD, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x01]).write(to: aggregateLocal.appendingPathComponent("本地人物.png"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x02]).write(to: aggregateSSD.appendingPathComponent("SSD场景.png"))
        let aggregateStore = AssetStore(rootURL: root.appendingPathComponent("AggregateAppData", isDirectory: true))
        await waitUntil("aggregate project load") { !aggregateStore.isLoadingProject }
        aggregateStore.importLocalFolder(aggregateLocal)
        await waitUntil("aggregate first folder import") { !aggregateStore.isImporting && aggregateStore.localFolders.count == 1 }
        aggregateStore.importLocalFolder(aggregateSSD)
        await waitUntil("aggregate second folder import") { !aggregateStore.isImporting && aggregateStore.localFolders.count == 2 }
        let aggregateAssets = aggregateStore.assetsInAllLocalFolders(
            search: "",
            filter: AssetFilter(),
            sort: .newest
        )
        precondition(aggregateAssets.count == 2, "全部照片入口必须穿透汇总所有已链接文件夹")
        precondition(Set(aggregateAssets.map(\.originalFilename)) == ["本地人物.png", "SSD场景.png"])
        precondition(aggregateStore.allLocalFolderAssetCount == 2)

        print("LocalFolderImportSelfTest passed")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "LocalFolderImportSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }

    @MainActor
    private static func waitUntil(
        _ label: String,
        diagnostics: @escaping @MainActor () -> String = { "" },
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out: \(label) \(diagnostics())")
    }
}
