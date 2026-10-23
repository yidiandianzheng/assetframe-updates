import Foundation

@main
struct DirectGalleryImportSelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-direct-gallery-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let files = (0..<3).map { root.appendingPathComponent("image-\($0).png") }
        for file in files { try png.write(to: file) }
        let dataRoot = root.appendingPathComponent("state")
        let store = AssetStore(rootURL: dataRoot)
        while store.isLoadingProject { try await Task.sleep(for: .milliseconds(5)) }
        store.stageImages(files)
        while store.isImporting { try await Task.sleep(for: .milliseconds(5)) }
        store.cancelBackgroundMetadata()
        let gallery = store.assets(for: .allGallery, search: "")
        precondition(gallery.count == 3, "Imported records must be visible without review confirmation")
        precondition(store.assets(for: .allGallery, search: "image-1").count == 1)
        let id = store.pendingImports[0].id
        _ = store.performSetRating(3, on: [.pending(id)])
        precondition(store.assets(for: .allGallery, search: "").count == 3, "Rating must not duplicate or hide a record")
        precondition(store.assets(for: .allGallery, search: "").filter { $0.starRating == 3 }.count == 1)
        // Remaining records still use the backward-compatible import manifest.
        // The new UI must display those after restart without a review screen.
        await store.flushPendingImportManifest()
        await store.flushCurrentProject()
        let restarted = AssetStore(rootURL: dataRoot)
        while restarted.isLoadingProject { try await Task.sleep(for: .milliseconds(5)) }
        let deadline = Date.now.addingTimeInterval(5)
        while restarted.assets(for: .allGallery, search: "").count != 3 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        restarted.cancelBackgroundMetadata()
        precondition(restarted.assets(for: .allGallery, search: "").count == 3)
        for file in files { let actual = try Data(contentsOf: file); precondition(actual == png) }
        print("DirectGalleryImportSelfTest passed")
    }
}
