import AppKit
import Foundation

private final class TestPendingSourceTrashService: PendingSourceTrashing, @unchecked Sendable {
    func moveToTrash(_ url: URL) throws {
        if url.lastPathComponent.contains("模拟失败") {
            throw NSError(
                domain: "PendingReviewSelfTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "模拟权限不足"]
            )
        }
        try FileManager.default.removeItem(at: url)
    }
}

@main
struct PendingReviewSelfTest {
    @MainActor
    static func main() async throws {
        testSingleReviewEntry()
        try testQueueNavigation()
        testTypeSelection()
        testPendingImportFocus()
        try testLegacyPendingDecode()
        try await testBulkKeepOnlyUnreviewed()
        try await testReviewPersistenceImportAndSourceTrash()
        print("PendingReviewSelfTest passed")
    }

    private static func testSingleReviewEntry() {
        precondition(SavedView.quickReview.presentation == .gallery, "旧快速筛图标识仅兼容解析到画册")
        precondition(!SavedView.allCases.contains { $0.rawValue == "待导入" }, "正式导航不得重复保留待导入入口")
        precondition(Notification.Name.importedAssetsAvailable.rawValue == "importedAssetsAvailable", "导入完成后发布画册可用通知")
    }

    private static func testTypeSelection() {
        let person = makePendingReviewItem(id: "PERSON", status: .unreviewed, type: .person)
        let scene = makePendingReviewItem(id: "SCENE", status: .unreviewed, type: .scene)
        var selection = PendingReviewTypeSelection()

        precondition(selection.includes(person) && selection.includes(scene), "未筛选时应显示全部类型")
        selection.toggle(.person)
        precondition(selection.includes(person) && !selection.includes(scene), "单选类型时只应显示该类型")
        selection.toggle(.scene)
        precondition(selection.includes(person) && selection.includes(scene), "类型筛选应支持多选并按“或”匹配")
        selection.toggle(.person)
        precondition(!selection.includes(person) && selection.includes(scene), "再次点击应取消对应类型")
        selection.selectOnly(.person)
        precondition(selection.selectedTypes == [.person], "只看当前类型应替换已有多选")
        selection.clear()
        precondition(!selection.isActive && selection.includes(scene), "清除后应恢复全部类型")
    }

    private static func testPendingImportFocus() {
        let orderedIDs = ["A", "B", "C"]
        let newlySelected = PendingImportFocusResolver.resolve(
            previousSelection: ["A"],
            selection: ["A", "C"],
            currentFocus: "A",
            orderedIDs: orderedIDs
        )
        precondition(newlySelected == "C", "新增勾选的图片应该成为右侧当前图片")

        let retainedFocus = PendingImportFocusResolver.resolve(
            previousSelection: ["A", "C"],
            selection: ["A"],
            currentFocus: "A",
            orderedIDs: orderedIDs
        )
        precondition(retainedFocus == "A", "取消其他勾选时应保留仍选中的当前图片")

        let fallbackFocus = PendingImportFocusResolver.resolve(
            previousSelection: ["A", "C"],
            selection: ["C"],
            currentFocus: "A",
            orderedIDs: orderedIDs
        )
        precondition(fallbackFocus == "C", "当前图片被取消后应落到剩余勾选项")

        precondition(
            PendingImportFocusResolver.reconcile(currentFocus: "C", availableIDs: ["A", "B"]) == nil,
            "图片从待导入清单移除后必须清空右侧焦点"
        )
    }

    private static func testQueueNavigation() throws {
        let ids = (0..<100).map { "ITEM-\($0)" }
        var queue = PendingReviewQueue(itemIDs: ids, preferredID: "ITEM-50")
        precondition(queue.currentID == "ITEM-50")
        queue.selectNext()
        precondition(queue.currentID == "ITEM-51")
        queue.remove("ITEM-51")
        precondition(queue.currentID == "ITEM-52", "删除当前项后应留在原位置显示下一张")
        queue.reconcile(availableIDs: Array(ids.prefix(60)), appendingNewItems: false)
        precondition(queue.itemIDs.count == 59)
        precondition(queue.currentID == "ITEM-52")
        queue.reconcile(availableIDs: ids + ["ITEM-100"], appendingNewItems: true)
        precondition(queue.itemIDs.last == "ITEM-100")

        var filteredQueue = PendingReviewQueue(itemIDs: ids, preferredID: "ITEM-50")
        filteredQueue.replaceItems(with: ["ITEM-10", "ITEM-20"], preferredID: "ITEM-10")
        precondition(filteredQueue.itemIDs == ["ITEM-10", "ITEM-20"])
        precondition(filteredQueue.currentID == "ITEM-10", "进入废片回看时应落到第一张废片")
        filteredQueue.selectNext()
        filteredQueue.replaceItems(with: ["ITEM-10", "ITEM-20", "ITEM-30"])
        precondition(filteredQueue.currentID == "ITEM-20", "废片列表刷新时应保留仍存在的当前图片")
        filteredQueue.replaceItems(with: ["ITEM-10", "ITEM-30"])
        precondition(filteredQueue.currentID == "ITEM-30", "取消当前废片标记后应继续显示下一张废片")
        filteredQueue.replaceItems(with: ids)
        precondition(filteredQueue.itemIDs == ids, "退出废片回看后应恢复原批次顺序")
    }

    private static func testLegacyPendingDecode() throws {
        let item = PendingImportItem(
            id: "LEGACY",
            stagedPath: "/tmp/legacy.png",
            originalSourcePath: "/tmp/original.png",
            originalFilename: "legacy.png",
            sourceFileID: "legacy",
            sourceFileSize: 8,
            sourceModifiedAt: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            suggestedType: .person,
            category: .project,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(item)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "reviewStatus")
        object.removeValue(forKey: "manualTags")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PendingImportItem.self, from: legacyData)
        precondition(decoded.effectiveReviewStatus == .unreviewed)
        precondition(decoded.normalizedManualTags.isEmpty)
    }

    @MainActor
    private static func testBulkKeepOnlyUnreviewed() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let store = AssetStore(rootURL: root)
        await waitUntil { !store.isLoadingProject }
        store.pendingImports = [
            makePendingReviewItem(id: "UNREVIEWED", status: .unreviewed),
            makePendingReviewItem(id: "DISCARDED", status: .discarded),
            makePendingReviewItem(id: "KEPT", status: .kept),
            makePendingReviewItem(id: "OUTSIDE-SCOPE", status: .unreviewed)
        ]

        let changed = store.keepUnreviewedPendingImports(["UNREVIEWED", "DISCARDED", "KEPT"])
        precondition(changed == 1, "全部通过只应处理作用域内的待判断图片")
        precondition(store.pendingImport(withID: "UNREVIEWED")?.effectiveReviewStatus == .kept)
        precondition(store.pendingImport(withID: "DISCARDED")?.effectiveReviewStatus == .discarded, "废片不得被全部通过覆盖")
        precondition(store.pendingImport(withID: "KEPT")?.effectiveReviewStatus == .kept)
        precondition(store.pendingImport(withID: "OUTSIDE-SCOPE")?.effectiveReviewStatus == .unreviewed, "其他批次不得被修改")
        precondition(
            store.keepUnreviewedPendingImports(["UNREVIEWED", "DISCARDED", "KEPT"]) == 0,
            "没有待判断图片时不应重复修改"
        )
        await store.flushPendingImportManifest()
    }

    private static func makePendingReviewItem(
        id: String,
        status: PendingReviewStatus,
        type: AssetType = .unclassified
    ) -> PendingImportItem {
        PendingImportItem(
            id: id,
            stagedPath: "/tmp/\(id).png",
            originalSourcePath: "/tmp/source-\(id).png",
            originalFilename: "\(id).png",
            sourceFileID: id,
            sourceFileSize: 8,
            sourceModifiedAt: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            suggestedType: type,
            category: .pending,
            createdAt: Date.now,
            reviewStatus: status
        )
    }

    @MainActor
    private static func testReviewPersistenceImportAndSourceTrash() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let external = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: external)
        }

        let keptSource = external.appendingPathComponent("保留模特.png")
        try writePNG(to: keptSource, color: .systemGreen)
        let service = TestPendingSourceTrashService()
        let store = AssetStore(rootURL: root, pendingSourceTrashService: service)
        await waitUntil { !store.isLoadingProject }
        store.stageImages([keptSource])
        await waitUntil { !store.isImporting && store.pendingImports.count == 1 }

        let keptID = store.pendingImports[0].id
        store.updatePendingImport(keptID, type: .person)
        store.updatePendingImport(keptID, category: .common)
        store.updatePendingImport(keptID, manualTags: ["模特", "长发", "模特"])
        store.setPendingReviewStatus(keptID, status: .kept)
        await store.flushPendingImportManifest()

        let reloaded = AssetStore(rootURL: root, pendingSourceTrashService: service)
        await waitUntil { !reloaded.isLoadingProject && reloaded.pendingImports.count == 1 }
        let restored = reloaded.pendingImports[0]
        precondition(restored.effectiveReviewStatus == .kept)
        precondition(restored.normalizedManualTags == ["模特", "长发"])

        reloaded.confirmKeptPendingImports()
        await waitUntil { !reloaded.isImporting && reloaded.pendingImports.isEmpty }
        let imported = reloaded.assets.first { $0.originalFilename == keptSource.lastPathComponent }!
        precondition(imported.type == .person)
        precondition(imported.category == .common)
        precondition(imported.normalizedTags == ["模特", "长发"])
        precondition(imported.decision == .pending, "筛图保留不应越权改成正式使用")
        precondition(fileManager.fileExists(atPath: keptSource.path), "保留项的原下载文件必须继续存在")

        let discardedSource = external.appendingPathComponent("淘汰模特.png")
        try writePNG(to: discardedSource, color: .systemRed)
        reloaded.stageImages([discardedSource])
        await waitUntil { !reloaded.isImporting && reloaded.pendingImports.count == 1 }
        let discarded = reloaded.pendingImports[0]
        reloaded.setPendingReviewStatus(discarded.id, status: .discarded)
        precondition(fileManager.fileExists(atPath: discardedSource.path), "标为废片时不得立即删除原下载文件")
        precondition(discarded.stagedPath == discarded.originalSourcePath, "原位管理不得创建软件副本")
        let revisionBeforeSourceTrash = reloaded.contentRevision
        let deletedDiscardedIDs = await reloaded.trashDiscardedPendingImports([discarded.id])
        precondition(deletedDiscardedIDs == [discarded.id])
        precondition(!fileManager.fileExists(atPath: discardedSource.path))
        precondition(!fileManager.fileExists(atPath: discarded.stagedPath))
        precondition(reloaded.pendingImports.isEmpty)
        precondition(
            reloaded.contentRevision > revisionBeforeSourceTrash,
            "待确认条目移除后必须刷新文件夹画册快照"
        )

        let changedSource = external.appendingPathComponent("变化模特.png")
        try writePNG(to: changedSource, color: .systemBlue)
        reloaded.stageImages([changedSource])
        await waitUntil { !reloaded.isImporting && reloaded.pendingImports.count == 1 }
        let changed = reloaded.pendingImports[0]
        try Data([1, 2, 3, 4]).append(to: changedSource)
        let ignoredUnmarkedIDs = await reloaded.trashDiscardedPendingImports([changed.id])
        precondition(ignoredUnmarkedIDs.isEmpty, "未标为废片的图片不得进入统一删除")
        reloaded.setPendingReviewStatus(changed.id, status: .discarded)
        let changedDeletedIDs = await reloaded.trashDiscardedPendingImports([changed.id])
        precondition(changedDeletedIDs.isEmpty)
        precondition(fileManager.fileExists(atPath: changedSource.path))
        precondition(fileManager.fileExists(atPath: changed.stagedPath))
        let revisionBeforeDiscard = reloaded.contentRevision
        reloaded.discardPendingImports([changed.id])
        precondition(fileManager.fileExists(atPath: changedSource.path), "移出待确认不得删除原文件")
        precondition(reloaded.pendingImports.isEmpty)
        precondition(
            reloaded.contentRevision > revisionBeforeDiscard,
            "画册右键移出待确认后必须立即移除卡片"
        )

        let recoverableSource = external.appendingPathComponent("移出待确认模特.png")
        try writePNG(to: recoverableSource, color: .systemPurple)
        reloaded.stageImages([recoverableSource])
        await waitUntil { !reloaded.isImporting && reloaded.pendingImports.count == 1 }
        let recoverable = reloaded.pendingImports[0]
        reloaded.updatePendingImport(recoverable.id, type: .person)
        reloaded.updatePendingImport(recoverable.id, manualTags: ["可恢复"])
        let trashedCountBeforePendingRemoval = reloaded.trashedAssets.count
        reloaded.movePendingImportToTrash(recoverable.id)
        precondition(reloaded.pendingImports.isEmpty)
        precondition(reloaded.trashedAssets.count == trashedCountBeforePendingRemoval, "待确认记录不得制造 App 回收站资产")
        precondition(fileManager.fileExists(atPath: recoverableSource.path), "移出待确认不得删除原文件")

        let failedSource = external.appendingPathComponent("模拟失败模特.png")
        try writePNG(to: failedSource, color: .systemOrange)
        reloaded.stageImages([failedSource])
        await waitUntil { !reloaded.isImporting && reloaded.pendingImports.count == 1 }
        let failed = reloaded.pendingImports[0]
        reloaded.setPendingReviewStatus(failed.id, status: .discarded)
        let failedDeletedIDs = await reloaded.trashDiscardedPendingImports([failed.id])
        precondition(failedDeletedIDs.isEmpty)
        precondition(fileManager.fileExists(atPath: failedSource.path))
        precondition(fileManager.fileExists(atPath: failed.stagedPath))
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for pending review state")
    }

    private static func writePNG(to url: URL, color: NSColor) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 320,
            pixelsHigh: 480,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "PendingReviewSelfTest", code: 2)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 480).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PendingReviewSelfTest", code: 3)
        }
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
