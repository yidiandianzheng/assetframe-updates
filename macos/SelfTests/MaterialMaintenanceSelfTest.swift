import Foundation
import AppKit
import PDFKit
import SQLite3
import Darwin

@main struct MaterialMaintenanceSelfTest {
    private static func crashChange(_ before: MaterialSnapshot) throws -> MaterialSnapshot {
        var after = before
        for i in after.materials.indices { after.materials[i].note = "进程退出边界提交" }
        var history = before.editHistory ?? .init()
        history.append(try MaterialUndoPatch(before: before.materials, after: after.materials))
        after.editHistory = history
        return after
    }
    private static func crashChild() async throws {
        let mode = CommandLine.arguments[1]
        let db = MaterialDatabase(root: URL(fileURLWithPath: CommandLine.arguments[2]))
        #if ASSETFRAME_SELF_TEST
        db.transactionCheckpoint = { stage in
            if mode == "--crash-in-transaction" && stage == "materials-written" { _exit(91) }
            if mode == "--crash-after-commit" && stage == "committed" { _exit(92) }
        }
        #endif
        let before = try await db.load()
        try await db.commit(crashChange(before), previous: before)
        _exit(92)
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--crash-") {
            try await crashChild(); return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-qa.maintenance-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache/ScreenPreviews")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        for i in 0..<10 {
            let file = cache.appendingPathComponent(String(format: "%064x", i)+".png")
            try Data(repeating: UInt8(i), count: 100).write(to: file)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i+1))], ofItemAtPath: file.path)
        }
        let budget = PreviewCacheBudget(byteBudget: 800, reserveBytes: 0, chunkItemLimit: 1, chunkSeconds: 0.002, initialDelaySeconds: 0)
        budget.noteInteraction(); budget.schedule(root: cache.deletingLastPathComponent(), isCurrent: { true })
        for _ in 0..<300 {
            if budget.snapshot(root: cache.deletingLastPathComponent()).checked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let budgetState = budget.snapshot(root: cache.deletingLastPathComponent())
        precondition(budgetState.checked && !budgetState.scanning && budgetState.scanChunks >= 10 && budgetState.observedBytes <= 720)
        precondition(budget.snapshot(root: root).readErrors == 0)
        precondition(budgetState.removedFiles == 3, "Resumed full scan retires only the coldest entries")
        let names = try fm.contentsOfDirectory(atPath: cache.path)
        precondition(names.contains(String(format: "%064x", 9)+".png"))

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        for y in 0..<32 { for x in 0..<64 {
            let offset = y * bitmap.bytesPerRow + x * 3
            pixels[offset] = UInt8(x * 4); pixels[offset + 1] = UInt8(y * 8); pixels[offset + 2] = 50
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let oldPath = root.appendingPathComponent("old.png"); try png.write(to: oldPath)
        var original = await GlobalMaterialStore.record(oldPath)!
        original.id = "move-1"; original.name = "原素材"; original.tags = ["保留标签"]; original.rating = 5; original.note = "原备注"
        let candidateFolder = root.appendingPathComponent("renamed"); try fm.createDirectory(at: candidateFolder, withIntermediateDirectories: true)
        let moved = candidateFolder.appendingPathComponent("finder-renamed.png"), duplicate = candidateFolder.appendingPathComponent("copy.png")
        try fm.moveItem(at: oldPath, to: moved); try fm.copyItem(at: moved, to: duplicate)
        var withoutHash = original; withoutHash.id = "no-hash"; withoutHash.fingerprint = "source:unknown"; withoutHash.contentFingerprint = nil
        let found = MaterialRelocationScan.scan(materials: [original, withoutHash], directory: candidateFolder)
        precondition(found.candidates.count == 2 && found.missingWithoutFingerprint == 1 && !found.truncated)
        var same = original; same.id = "same"; same.sourcePath = duplicate.path
        let grouped = MaterialSimilarityScan.scan([original, same], includeVisual: false)
        precondition(grouped.groups.count == 1 && Set(grouped.groups[0].materialIDs) == [original.id, same.id])
        let h1 = MaterialSimilarityScan.visualHash(moved), h2 = MaterialSimilarityScan.visualHash(duplicate)
        precondition(h1 != nil && h1?.hash == h2?.hash && h1?.ratio == 2)
        let unsupported = candidateFolder.appendingPathComponent("bad.png"); try Data("not an image".utf8).write(to: unsupported)
        precondition(MaterialSimilarityScan.visualHash(unsupported) == nil)

        let pdf = PDFDocument(), image = NSImage(data: png)!
        pdf.insert(PDFPage(image: image)!, at: 0); pdf.insert(PDFPage(image: image)!, at: 1)
        let pdfURL = root.appendingPathComponent("two-pages.pdf"); precondition(pdf.write(to: pdfURL))
        precondition(PDFPreviewDocument.load(pdfURL)?.value.pageCount == 2)
        precondition(PDFPreviewDocument.load(unsupported) == nil)
        var format = original
        for ext in ["psd", "psb", "ai", "eps", "pdf"] {
            format.sourcePath = root.appendingPathComponent("format." + ext).path
            precondition(MaterialDocumentPreview.usesDocumentPreview(format))
        }
        format.sourcePath = moved.path
        precondition(!MaterialDocumentPreview.usesDocumentPreview(format))

        let library = root.appendingPathComponent("test.assetframelibrary")
        let db = MaterialDatabase(root: library); let empty = try await db.load()
        let link = ProjectMaterialLink(id: "reference", projectID: "project", materialID: original.id, use: .working, createdAt: .now)
        try await db.commit(MaterialSnapshot(materials: [original], links: [link]), previous: empty)
        var store: GlobalMaterialStore? = GlobalMaterialStore(rootURL: library)
        await store!.waitUntilReady()
        try await store!.relocate(original.id, to: moved)
        var state = try await db.load()
        precondition(state.materials[0].id == original.id && state.materials[0].tags == original.tags && state.materials[0].rating == original.rating && state.links == [link])
        precondition(state.materials[0].sourcePath == moved.path)
        store!.batchUpdate([original.id]) { $0.note = "批量新备注" }
        try await store!.saveNow().get()
        precondition(store!.canUndoEdit && store!.undoHistoryCount == 1)
        try await store!.pauseSession().get(); store = nil
        store = GlobalMaterialStore(rootURL: library); await store!.waitUntilReady()
        precondition(store!.canUndoEdit && store!.undoHistoryCount == 1, "Committed undo survives reopening")
        let undone = await store!.undoEdit(); precondition(undone)
        state = try await db.load(); precondition(state.materials[0].note == original.note && state.editHistory?.redo.count == 1)
        try await store!.pauseSession().get(); store = nil
        store = GlobalMaterialStore(rootURL: library); await store!.waitUntilReady()
        precondition(store!.canRedoEdit); let redone = await store!.undoEdit(redo: true); precondition(redone)
        state = try await db.load(); precondition(state.materials[0].note == "批量新备注")

        var connection: OpaquePointer?; precondition(sqlite3_open(db.url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        precondition(sqlite3_exec(connection, "CREATE TRIGGER history_failure BEFORE UPDATE ON history BEGIN SELECT RAISE(ABORT,'test history failure'); END;", nil, nil, nil) == SQLITE_OK)
        let beforeFailure = try await db.load()
        store!.batchUpdate([original.id]) { $0.note = "不得提交" }
        let failed = await store!.saveNow()
        if case .success = failed { preconditionFailure("History failure must roll back the entire user edit") }
        let afterFailure = try await db.load()
        precondition(beforeFailure.materials == afterFailure.materials && beforeFailure.editHistory == afterFailure.editHistory)
        precondition(sqlite3_exec(connection, "DROP TRIGGER history_failure", nil, nil, nil) == SQLITE_OK)
        _ = await store!.pauseSession(); store = nil
        // External row edits are not overwritten by a commit based on stale data.
        var staleDesired = afterFailure; staleDesired.materials[0].rating = 1
        var external = afterFailure; external.materials[0].note = "外部修改"
        try await db.commit(external, previous: afterFailure)
        do { try await db.commit(staleDesired, previous: afterFailure); preconditionFailure("Stale transaction must be rejected") }
        catch { }
        let preserved = try await db.load(); precondition(preserved.materials[0].note == "外部修改" && preserved.materials[0].rating == 5)
        for mode in ["--crash-in-transaction", "--crash-after-commit"] {
            let crashRoot = root.appendingPathComponent(mode.dropFirst(2).description + ".assetframelibrary")
            let crashDB = MaterialDatabase(root: crashRoot)
            let initial = try await crashDB.load()
            let baseline = MaterialSnapshot(materials: preserved.materials, links: preserved.links, editHistory: .init())
            try await crashDB.commit(baseline, previous: initial)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode, crashRoot.path]
            try child.run(); child.waitUntilExit()
            precondition(child.terminationStatus == (mode == "--crash-in-transaction" ? 91 : 92))
            let recovered = try await crashDB.load()
            let expected = try mode == "--crash-in-transaction" ? baseline : crashChange(baseline)
            precondition(recovered.materials == expected.materials && recovered.links == expected.links && recovered.editHistory == expected.editHistory, "Crash recovery must keep user fields and history atomic")
        }
        let sourceBytes = try Data(contentsOf: moved); precondition(sourceBytes == png)
        print("MaterialMaintenanceSelfTest passed: chunk resume and eviction, browsing pause, exact/ambiguous relocation, saved-ID/tag/reference preservation, exact/similar candidates, invalid images, PDF pages, durable undo/redo, atomic history failure rollback, real child-process crash before/after commit and stale-row protection")
    }
}
