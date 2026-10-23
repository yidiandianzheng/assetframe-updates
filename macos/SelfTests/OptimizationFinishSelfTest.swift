import Foundation
import AppKit
import CoreImage
import UniformTypeIdentifiers

@main struct OptimizationFinishSelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"]!)
        precondition(root.lastPathComponent.hasPrefix("assetframe-qa."))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let svg = root.appendingPathComponent("vector.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 360\"><rect width=\"640\" height=\"360\" fill=\"red\"/></svg>".utf8).write(to: svg)
        let doc = try SVGDocument.load(svg); precondition(doc.size == CGSize(width: 640, height: 360))
        precondition(doc.html().contains("connect-src 'none'"))
        for invalid in ["not svg", "<html/>", "<!DOCTYPE svg [<!ENTITY a SYSTEM 'file:///tmp/test'>]><svg>&a;</svg>"] {
            try Data(invalid.utf8).write(to: svg)
            do { _ = try SVGDocument.load(svg); preconditionFailure("Invalid SVG accepted") } catch { }
        }
        let monitor = LinkedFolderEventMonitor(roots: [root])
        var detected = false
        let observation = Task { for await event in monitor.events { if event == .filesystem { detected = true } } }
        try Data("event".utf8).write(to: root.appendingPathComponent("event.txt"))
        for _ in 0..<100 where !detected { try await Task.sleep(for: .milliseconds(100)) }
        precondition(detected && monitor.watching, "Real FSEvents callback missing")
        monitor.stop(); await observation.value; precondition(!monitor.watching)
        let database = MaterialDatabase(root: root.appendingPathComponent("Library"))
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let original = MaterialRecord(id: "one", kind: .document, name: "素材", sourcePath: source.path,
            originalFilename: "original.txt", fingerprint: "one", sourceLocations: [], fileSize: 8,
            createdAt: .now, tags: [], rating: 0, note: "")
        let empty = try await database.load()
        try await database.commit(MaterialSnapshot(materials: [original], links: []), previous: empty)
        let store = GlobalMaterialStore(rootURL: database.root, managedRoot: root.appendingPathComponent("Managed"))
        await store.waitUntilReady()
        store.batchUpdate(["one"]) { $0.tags = ["新标签"]; $0.rating = 4 }
        try await store.saveNow().get(); precondition(store.canUndoEdit)
        store.recordPreviewUsage("one"); try await store.saveNow().get()
        let used = store.materials[0].lastUsedAt
        let undone = await store.undoEdit(); precondition(undone)
        precondition(store.materials[0].tags.isEmpty && store.materials[0].rating == 0 && store.materials[0].lastUsedAt == used)
        let redone = await store.undoEdit(redo: true); precondition(redone && store.materials[0].rating == 4)
        let patch = try MaterialUndoPatch(before: [original], after: store.materials)
        var conflict = store.materials; conflict[0].rating = 5
        do { _ = try patch.restore(in: conflict); preconditionFailure("Conflict overwrote later edit") } catch { }
        _ = await store.pauseSession(); store.update("one") { $0.name = "inactive" }; try await store.saveNow().get()
        precondition(store.materials[0].name == "素材", "Inactive store admitted a user edit")
        store.resumeSession()
        let imports = root.appendingPathComponent("ImportFiles")
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        for n in 0..<640 { try Data("unique \(n)".utf8).write(to: imports.appendingPathComponent("\(n).txt")) }
        store.importFiles([imports])
        for _ in 0..<1000 where store.importAdded == 0 && store.isImporting { try await Task.sleep(for: .milliseconds(5)) }
        precondition(store.isImporting && store.importAdded > 0, "Fixture failed to pause a partial import")
        store.pauseImport(); await store.waitForImportCompletion()
        precondition(store.importPhase.contains("已暂停") && store.resumableImport != nil)
        let partial = store.materials.count
        _ = await store.pauseSession()
        let reopened = GlobalMaterialStore(rootURL: database.root, managedRoot: root.appendingPathComponent("Managed"))
        await reopened.waitUntilReady(); precondition(reopened.resumableImport != nil)
        reopened.resumeImport(); await reopened.waitForImportCompletion()
        precondition(reopened.resumableImport == nil && reopened.materials.count == 641 && reopened.materials.count > partial)
        precondition(Set(reopened.materials.map(\.id)).count == 641)
        let unchanged = try Data(contentsOf: source); precondition(unchanged == Data("original".utf8))
        let id = UUID().uuidString; SSDPreviewCache.selectLibrary(id)
        for n in 0..<4 {
            if n > 0 { try SSDPreviewCache.clearLibrary(id) }
            let directory = SSDPreviewCache.directory("Thumbnails"); precondition(SSDPreviewCache.prepare(directory))
            try Data(repeating: UInt8(n), count: 4096).write(to: directory.appendingPathComponent("cached.png"))
        }
        let cacheRoot = try SSDPreviewCache.libraryRoot(id)
        let before = PreviewCacheInventory.read(root: cacheRoot); precondition(before.files == 4 && before.bytes == 16384)
        let n = try SSDPreviewCache.pruneObsolete(id); precondition(n == 2)
        let after = PreviewCacheInventory.read(root: cacheRoot); precondition(after.files == 2 && after.bytes == 8192)
        precondition(fm.fileExists(atPath: SSDPreviewCache.directory("Thumbnails").appendingPathComponent("cached.png").path))
        let huge = root.appendingPathComponent("huge.tiff")
        let generated = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 10000, y: 8000), "inputColor0": CIColor(red: 1, green: 0, blue: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 1)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 10000, height: 8000))
        try CIContext(options: [.useSoftwareRenderer: true]).writeTIFFRepresentation(of: generated, to: huge, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
        guard let renderer = OriginalTileRenderer(url: huge) else { fatalError("Tile renderer unavailable") }
        let tile = renderer.tile(rect: CGRect(x: 4096, y: 4096, width: 512, height: 512), scale: 1)
        precondition(tile?.width == 512 && tile?.height == 512)
        let bounded = renderer.tile(rect: CGRect(x: 0, y: 0, width: 5000, height: 4000), scale: 8)
        precondition(bounded!.width <= 1024 && bounded!.height <= 1024)
        renderer.stop(); precondition(renderer.tile(rect: CGRect(x: 0, y: 0, width: 256, height: 256), scale: 1) == nil)
        _ = await reopened.pauseSession()
        let guardDB = MaterialDatabase(root: root.appendingPathComponent("GuardLibrary"))
        let emptyGuard = try await guardDB.load()
        let guarded = MaterialSnapshot(materials: [original], links: [])
        try await guardDB.commit(guarded, previous: emptyGuard)
        let awayDB = root.appendingPathComponent("guard-away.sqlite")
        try fm.moveItem(at: guardDB.url, to: awayDB)
        do { try await guardDB.commit(guarded, previous: guarded); preconditionFailure("Missing database recreated by commit") } catch { }
        do { _ = try await guardDB.load(); preconditionFailure("Missing database recreated by reload") } catch { }
        precondition(!fm.fileExists(atPath: guardDB.url.path))
        try fm.moveItem(at: awayDB, to: guardDB.url)
        let recovered = try await guardDB.load(); precondition(recovered.materials == guarded.materials)
        let missingVolumeRoot = URL(fileURLWithPath: "/Volumes/AssetFrame-QA-Absent-\(UUID().uuidString)/library")
        let missingVolumeDB = MaterialDatabase(root: missingVolumeRoot)
        do { _ = try await missingVolumeDB.load(); preconditionFailure("Offline mount directory created") } catch { }
        precondition(!fm.fileExists(atPath: missingVolumeRoot.deletingLastPathComponent().path))
        print("OptimizationFinishSelfTest passed: SVG validation, actual folder event and stop, committed undo/redo, usage preservation, conflicts, inactive edit gate, partial import pause and restart resume, cache inventory/prune/source protection, bounded 80MP region tiles")
    }
}
