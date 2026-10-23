import AppKit
import Foundation

@main
struct AssetFrameSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyAssets = rootURL.appendingPathComponent("Assets", isDirectory: true)
        let fakeSSD = rootURL.appendingPathComponent("FakeSSD", isDirectory: true)
        try fileManager.createDirectory(at: legacyAssets, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeSSD, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let source = legacyAssets.appendingPathComponent("测试道具.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: source)
        let originalAsset = AssetItem(
            id: "ASSET-001", name: "测试道具", type: .prop, imagePath: source.path, originalFilename: source.lastPathComponent,
            decision: .confirmed, note: "", reuse: .s, project: "旧项目", episodes: ["第1集"], candidatePlan: .a,
            version: "v01", purpose: .propSingle, category: .project, qaResult: .passed, productionStatus: .adopted,
            assetDescription: "迁移测试", repairReason: "", fingerprint: "", shapeState: "", promptSource: "", generationPlatform: "",
            position: CanvasPoint(x: 100, y: 100), createdAt: Date()
        )
        let legacy = LibraryData(
            assets: [originalAsset],
            groups: [AssetGroup(id: "GROUP-01", episode: "第1集", name: "测试资产组", position: CanvasPoint(x: 10, y: 10))],
            relations: [AssetRelation(groupId: "GROUP-01", assetId: originalAsset.id)]
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: rootURL.appendingPathComponent("library.json"))

        let store = AssetStore(rootURL: rootURL, managedLibrarySSDURL: fakeSSD)
        await waitUntil { !store.isLoadingProject }
        precondition(store.assets.count == 1)
        precondition(!SavedView.allCases.contains(where: { $0.rawValue == "资产关系" }))
        precondition(store.assets[0].projectID == "legacy-library")
        precondition(fileManager.fileExists(atPath: rootURL.appendingPathComponent("library.pre-sqlite-backup.json").path))
        precondition(fileManager.fileExists(atPath: store.currentProject.databasePath))
        let migratedSnapshot = try await ProjectDatabase(url: URL(fileURLWithPath: store.currentProject.databasePath)).load()
        precondition(migratedSnapshot.library.groups.count == 1)
        precondition(migratedSnapshot.library.relations.count == 1, "旧画布数据只做兼容保存，不应阻塞资产库升级")

        store.moveAssetToTrash(originalAsset.id)
        precondition(store.activeAssets.isEmpty)
        precondition(store.trashedAssets.count == 1)
        store.restoreAsset(originalAsset.id)
        precondition(store.activeAssets.count == 1)

        // Eagle 式元数据应兼容旧记录，并能参与智能视图、组合筛选和持久化。
        precondition(store.assets[0].normalizedTags.isEmpty)
        precondition(store.assets[0].starRating == 0)
        precondition(!store.assets[0].isMaster)
        store.updateAsset(originalAsset.id) {
            $0.tags = ["主线道具", "已验证"]
            $0.rating = 5
            $0.isMasterAsset = true
            $0.sourceURL = "https://example.com/reference"
        }
        precondition(store.availableTags == ["已验证", "主线道具"])
        precondition(store.assets(for: .master, search: "", filter: AssetFilter(), sort: .newest).map(\.id) == [originalAsset.id])
        precondition(store.assets(for: .favorites, search: "", filter: AssetFilter(), sort: .newest).map(\.id) == [originalAsset.id])
        var tagFilter = AssetFilter()
        tagFilter.tag = "已验证"
        tagFilter.minimumRating = 5
        precondition(store.assets(for: .allGallery, search: "example.com", filter: tagFilter, sort: .rating).map(\.id) == [originalAsset.id])

        let externalFolder = rootURL.appendingPathComponent("External", isDirectory: true)
        try fileManager.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        let importedSource = externalFolder.appendingPathComponent("新增道具.png")
        let personSource = externalFolder.appendingPathComponent("新增人物.png")
        let sceneSource = externalFolder.appendingPathComponent("新增场景.png")
        let commonSource = externalFolder.appendingPathComponent("通用符号.png")
        let lowResolutionSource = externalFolder.appendingPathComponent("高清替换测试_1K.png")
        let highResolutionSource = externalFolder.appendingPathComponent("高清替换测试_4K.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]).write(to: importedSource)
        try Data([0x89, 0x50, 0x4e, 0x47, 2, 3, 4, 5]).write(to: personSource)
        try Data([0x89, 0x50, 0x4e, 0x47, 3, 4, 5, 6]).write(to: sceneSource)
        try Data([0x89, 0x50, 0x4e, 0x47, 4, 5, 6, 7]).write(to: commonSource)
        try writePNG(width: 1_024, height: 512, to: lowResolutionSource)
        try writePNG(width: 4_096, height: 2_048, to: highResolutionSource)
        store.importImages([importedSource, importedSource, personSource, sceneSource, commonSource, lowResolutionSource])
        await waitUntil { !store.isImporting }
        precondition(store.importProgress?.phase == .completed)
        precondition(store.importProgress?.imported == 5)
        precondition(store.importProgress?.skipped == 1)
        precondition(store.assets.count == 6)

        let importedID = store.assets.first(where: { $0.imagePath == importedSource.path })!.id
        let personID = store.assets.first(where: { $0.imagePath == personSource.path })!.id
        let sceneID = store.assets.first(where: { $0.imagePath == sceneSource.path })!.id
        let commonID = store.assets.first(where: { $0.imagePath == commonSource.path })!.id
        let resolutionID = store.assets.first(where: { $0.imagePath == lowResolutionSource.path })!.id
        precondition(store.assets.first(where: { $0.id == resolutionID })?.resolutionLabel == "1K")
        let replaced = await store.replaceSource(for: resolutionID, with: highResolutionSource)
        precondition(replaced)
        let highResolutionAsset = store.assets.first(where: { $0.id == resolutionID })!
        precondition(highResolutionAsset.resolutionLabel == "4K")
        precondition(highResolutionAsset.pixelWidth == 4_096 && highResolutionAsset.pixelHeight == 2_048)
        precondition(highResolutionAsset.sourceVersions?.contains(where: { $0.path == lowResolutionSource.path && $0.resolutionLabel == "1K" }) == true)
        precondition(fileManager.fileExists(atPath: lowResolutionSource.path), "替换高清版不得删除 1K 旧原图")
        store.updateAsset(importedID) { $0.type = .prop; $0.category = .project; $0.exportName = "新增道具" }
        store.updateAsset(personID) { $0.type = .person; $0.category = .project; $0.exportName = "新增人物" }
        store.updateAsset(sceneID) { $0.type = .scene; $0.category = .project; $0.exportName = "新增场景" }
        store.updateAsset(commonID) { $0.type = .fixedSymbol; $0.category = .common; $0.exportName = "通用符号" }
        store.updateAsset(resolutionID) { $0.type = .prop; $0.category = .project; $0.exportName = "高清替换测试" }
        store.addToExportLibrary([importedID, personID, sceneID, commonID, resolutionID])
        await store.flushCurrentProject()

        let reloaded = AssetStore(rootURL: rootURL, managedLibrarySSDURL: fakeSSD)
        await waitUntil { !reloaded.isLoadingProject }
        precondition(reloaded.assets.count == 6)
        precondition(reloaded.exportNames[importedID] == "新增道具")
        let reloadedOriginal = reloaded.assets.first(where: { $0.id == originalAsset.id })!
        precondition(reloadedOriginal.normalizedTags == ["主线道具", "已验证"])
        precondition(reloadedOriginal.starRating == 5 && reloadedOriginal.isMaster)
        precondition(reloadedOriginal.sourceURL == "https://example.com/reference")

        let exportParent = rootURL.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: exportParent, withIntermediateDirectories: true)
        reloaded.exportLibrary(to: exportParent)
        await waitUntil {
            guard let phase = reloaded.exportProgress?.phase else { return false }
            return phase == .completed || phase == .failed
        }
        precondition(reloaded.exportProgress?.phase == .completed)
        let output = URL(fileURLWithPath: reloaded.exportProgress!.resultPath!)
        precondition(fileManager.fileExists(atPath: output.appendingPathComponent("道具资产").path))
        precondition(fileManager.fileExists(atPath: output.appendingPathComponent("人物资产").path))
        precondition(fileManager.fileExists(atPath: output.appendingPathComponent("场景资产").path))
        precondition(fileManager.fileExists(atPath: output.appendingPathComponent("通用资产").path))
        precondition(fileManager.fileExists(atPath: output.appendingPathComponent("资产清单.csv").path))
        let manifest = try String(contentsOf: output.appendingPathComponent("资产清单.csv"), encoding: .utf8)
        precondition(manifest.contains("4096 × 2048") && manifest.contains("4K"), "导出清单应记录最高分辨率原图")
        precondition(!manifest.contains("关联资产组"), "删除无限画布后，CSV 不应再输出画布关系字段")
        let exportedHighResolutionFile = try fileManager.contentsOfDirectory(at: output.appendingPathComponent("道具资产"), includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.contains("高清替换测试") })
        precondition(exportedHighResolutionFile != nil)
        let exportedFileSize = try exportedHighResolutionFile?.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let sourceFileSize = try highResolutionSource.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        precondition(exportedFileSize == sourceFileSize, "导出必须原图直接复制，不得压缩")

        // 回收站多选操作必须一次处理多条，且不得波及未在回收站的记录或原图。
        let batchIDs: Set<String> = [originalAsset.id, personID, sceneID]
        reloaded.moveAssetsToTrash(batchIDs)
        precondition(Set(reloaded.trashedAssets.map(\.id)).isSuperset(of: batchIDs))
        reloaded.restoreAssets(batchIDs)
        precondition(batchIDs.allSatisfy { id in reloaded.assets.first(where: { $0.id == id })?.deletedAt == nil })

        reloaded.addToExportLibrary([originalAsset.id])
        reloaded.moveAssetsToTrash(batchIDs)
        reloaded.permanentlyDeleteAssets([originalAsset.id, personID, commonID])
        precondition(reloaded.asset(withID: originalAsset.id) == nil)
        precondition(reloaded.asset(withID: personID) == nil)
        precondition(reloaded.asset(withID: commonID) != nil, "非回收站 ID 不得被永久删除")
        precondition(reloaded.asset(withID: sceneID)?.deletedAt != nil, "未选中的回收站记录应保留")
        precondition(reloaded.exportNames[originalAsset.id] == nil)
        precondition(fileManager.fileExists(atPath: source.path), "批量永久删除软件记录不得删除原图")
        precondition(fileManager.fileExists(atPath: personSource.path), "批量永久删除软件记录不得删除外部原图")
        await reloaded.flushCurrentProject()
        let batchSnapshot = try await ProjectDatabase(url: URL(fileURLWithPath: reloaded.currentProject.databasePath)).load()
        precondition(!batchSnapshot.library.relations.contains(where: { $0.assetId == originalAsset.id || $0.assetId == personID }))

        let projectRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = projectRoot.appendingPathComponent("人物/主角", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: projectRoot) }
        try Data([0x89, 0x50, 0x4e, 0x47, 9, 9, 9, 9]).write(to: nested.appendingPathComponent("递归扫描.png"))
        let projectRegistry = ProjectRegistry(rootURL: projectRoot, legacyAssetsURL: projectRoot.appendingPathComponent("Assets", isDirectory: true))
        let createdProject = projectRegistry.addProject(folderURL: projectRoot)
        precondition(projectRegistry.current.id == createdProject.id)
        let projectStore = AssetStore(rootURL: projectRoot, managedLibrarySSDURL: fakeSSD)
        await waitUntil { !projectStore.isLoadingProject && !projectStore.isImporting }
        precondition(projectStore.currentProject.id == createdProject.id)
        precondition(projectStore.assets.isEmpty && projectStore.pendingImports.isEmpty, "打开空项目不得自动扫描")
        projectStore.scanCurrentFolderForNewImages()
        await waitUntil { !projectStore.isImporting }
        precondition(projectStore.assets.isEmpty, "显式扫描不应绕过用户确认直接进正式库")
        precondition(projectStore.pendingImports.contains(where: { $0.originalFilename == "递归扫描.png" }))
        let firstPending = projectStore.pendingImports.first(where: { $0.originalFilename == "递归扫描.png" })!
        precondition(firstPending.stagedPath == nested.appendingPathComponent("递归扫描.png").path, "扫描必须原位引用图片")
        precondition(firstPending.suggestedType == .person, "应结合文件夹和文件名给出轻量分类建议")
        let originalScannedData = try Data(contentsOf: nested.appendingPathComponent("递归扫描.png"))
        let stagedScannedData = try Data(contentsOf: URL(fileURLWithPath: firstPending.stagedPath))
        precondition(stagedScannedData == originalScannedData, "待确认索引必须直接读取原字节")
        precondition(fileManager.fileExists(atPath: nested.appendingPathComponent("递归扫描.png").path), "扫描不得移动或删除原文件")
        projectStore.confirmPendingImports([firstPending.id])
        await waitUntil { !projectStore.isImporting }
        precondition(projectStore.assets.contains(where: { $0.originalFilename == "递归扫描.png" }))
        let confirmed = projectStore.assets.first(where: { $0.originalFilename == "递归扫描.png" })!
        precondition(confirmed.imagePath == nested.appendingPathComponent("递归扫描.png").path)
        precondition(confirmed.type == .person)
        let confirmedScannedData = try Data(contentsOf: URL(fileURLWithPath: confirmed.imagePath))
        precondition(confirmedScannedData == originalScannedData, "正式资产必须原位读取原字节")
        try fileManager.removeItem(at: nested.appendingPathComponent("递归扫描.png"))
        precondition(projectStore.fileLocation(for: confirmed.id)?.exists == false, "原文件删除后资产应明确显示失联")
        precondition(projectStore.copyFileLocation(for: confirmed.id), "失联后仍应允许复制记录路径用于排查")
        precondition(NSPasteboard.general.string(forType: .string) == confirmed.imagePath)
        precondition(confirmed.importSourcePath == nil, "正式资产只能记录当前文件路径")
        let newlyAdded = projectRoot.appendingPathComponent("场景/当前文件夹新增.png")
        try fileManager.createDirectory(at: newlyAdded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47, 8, 8, 8, 8]).write(to: newlyAdded)
        projectStore.scanCurrentFolderForNewImages()
        await waitUntil { !projectStore.isImporting }
        precondition(!projectStore.assets.contains(where: { $0.originalFilename == "当前文件夹新增.png" }))
        precondition(projectStore.pendingImports.contains(where: { $0.originalFilename == "当前文件夹新增.png" }))
        precondition(projectStore.importProgress != nil, "导入完成后应先展示结果")
        await projectStore.flushCurrentProject()

        // 待确认索引必须随项目持久化，原图继续留在原目录。
        let pendingReload = AssetStore(rootURL: projectRoot, managedLibrarySSDURL: fakeSSD)
        await waitUntil { !pendingReload.isLoadingProject && !pendingReload.isImporting }
        let restoredPending = pendingReload.pendingImports.first(where: { $0.originalFilename == "当前文件夹新增.png" })
        precondition(restoredPending != nil)
        pendingReload.confirmPendingImports([restoredPending!.id])
        await waitUntil { !pendingReload.isImporting }
        precondition(pendingReload.assets.contains(where: { $0.originalFilename == "当前文件夹新增.png" }))
        precondition(fileManager.fileExists(atPath: newlyAdded.path), "确认入库也不得影响原文件")
        pendingReload.scanCurrentFolderForNewImages()
        await waitUntil { !pendingReload.isImporting }
        precondition(pendingReload.pendingImports.isEmpty, "已确认的原文件和软件管理目录都不应重复扫描")
        try? await Task.sleep(for: .milliseconds(5_200))
        precondition(pendingReload.importProgress == nil, "导入完成提示应在约 5 秒后自动消失")
        await pendingReload.flushCurrentProject()

        // 已有项目再次打开时，必须直接读取资料库；不应再自动递归扫描并显示“导入中”。
        let reopenedProjectStore = AssetStore(rootURL: projectRoot, managedLibrarySSDURL: fakeSSD)
        await waitUntil { !reopenedProjectStore.isLoadingProject }
        precondition(!reopenedProjectStore.isImporting)
        precondition(!reopenedProjectStore.isProjectScanning)
        precondition(reopenedProjectStore.importProgress == nil)
        precondition(reopenedProjectStore.assets.count == pendingReload.assets.count)

        print("Migration, SQLite, trash, Eagle metadata, import, and export self-test passed")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for asynchronous operation")
    }

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AssetFrameSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法生成测试 PNG"])
        }
        try data.write(to: url, options: .atomic)
    }
}
