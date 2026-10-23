import Foundation

@main
struct LinkedFolderReadSelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-linked-read-\(UUID())").standardizedFileURL.resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        let child = a.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        let oldURL = a.appendingPathComponent("original.txt")
        try Data("original fixture".utf8).write(to: oldURL)
        let store = GlobalMaterialStore(rootURL: root.appendingPathComponent("library"))
        await store.waitUntilReady()
        store.importFiles([a, b])
        while store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.organization.folders.count == 2)
        guard let old = store.materials.first(where: { $0.sourcePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == oldURL.standardizedFileURL.path }) else {
            fatalError("Missing fixture: expected \(oldURL.path), records \(store.materials.compactMap(\.sourcePath)), results \(store.importResults), error \(store.persistenceError ?? "none")")
        }
        store.update(old.id) { $0.note = "keep note"; $0.tags = ["keep tag"]; $0.rating = 3; $0.sourceModifiedAt = $0.sourceModifiedAt?.addingTimeInterval(0.000_000_2) }
        _ = await store.saveNow()
        // Files added after linking must appear, including child directories
        // and a second root that was empty when linked.
        let newA = child.appendingPathComponent("new.txt")
        let newB = b.appendingPathComponent("new.txt")
        try Data("new A fixture".utf8).write(to: newA)
        try Data("new B fixture".utf8).write(to: newB)
        let read1 = await store.readLinkedFolders()
        precondition(read1)
        precondition(Set(store.materials.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0).standardizedFileURL.path }) == Set([oldURL, newA, newB].map { $0.standardizedFileURL.path }))
        let retained = store.materials.first { $0.id == old.id }!
        precondition(retained.note == "keep note" && retained.tags == ["keep tag"] && retained.rating == 3)
        precondition(!store.importProgressVisible, "Successful background reads must dismiss progress")
        let read2 = await store.readLinkedFolders()
        precondition(read2)
        precondition(store.materials.count == 3 && store.importRead == 0, "Unchanged files must not be read or duplicated")
        // Overlapping linked roots must not duplicate records or replace edits.
        store.importFiles([child])
        while store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        let read3 = await store.readLinkedFolders()
        precondition(read3)
        precondition(store.materials.count == 3)
        // A genuine timestamp change (even at the same size) must still be read.
        try Data("NEW B fixture".utf8).write(to: newB)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(2)], ofItemAtPath: newB.path)
        let changedRead = await store.readLinkedFolders()
        precondition(changedRead && store.importRead == 1, "Real same-size edits must not be skipped")
        let selectedNew = child.appendingPathComponent("selected-new.txt")
        try Data("selected new".utf8).write(to: selectedNew)
        try Data("changed again".utf8).write(to: newB)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(4)], ofItemAtPath: newB.path)
        let beforeSelection = store.materials.count
        let selectedRead = await store.readLinkedFolders(files: [selectedNew], directories: [child])
        precondition(selectedRead && store.importRead == 1)
        precondition(store.materials.count == beforeSelection + 1, "Reading additions must not also read changed files")
        let changedOnly = await store.readLinkedFolders(files: [newB], directories: [child])
        precondition(changedOnly && store.importRead == 1, "Changed files remain pending until selected")
        store.update(old.id) { $0.deletedAt = .now }
        _ = await store.saveNow()
        let read4 = await store.readLinkedFolders()
        precondition(read4)
        precondition(store.materials.first { $0.id == old.id }?.deletedAt != nil, "Reading a folder must not undo trash")
        // Preserve an unfinished recovery job instead of silently replacing it.
        let recovery = ImportResumeRecord(id: UUID(), paths: [newB.path], projectID: nil, localFolder: nil)
        try recovery.save(to: root.appendingPathComponent("library/material-import-resume.json"))
        let paused = GlobalMaterialStore(rootURL: root.appendingPathComponent("library"), paused: true)
        await paused.waitUntilReady()
        let inactiveRead = await paused.readLinkedFolders()
        precondition(!inactiveRead, "Inactive libraries must never start a scan")
        paused.resumeSession()
        let recoveryRead = await paused.readLinkedFolders()
        precondition(!recoveryRead && paused.resumableImport?.id == recovery.id,
                     "Unfinished jobs must not be replaced by automatic reads")
        _ = await paused.pauseSession()
        _ = await store.pauseSession()
        store.cancelBackgroundMetadata()
        print("LinkedFolderReadSelfTest passed: roots, late additions, nested files, unchanged fast path, overlapping roots, retained edits, trash protection and inactive session")
    }
}
