import Foundation

@main struct LibrarySessionSelfTest {
    @MainActor static func main() async throws {
        // Old browse files must still decode without display preferences.
        let oldState = LibraryBrowseState()
        let oldData = try JSONEncoder().encode(oldState)
        let decoded = try JSONDecoder().decode(LibraryBrowseState.self, from: oldData)
        precondition(decoded.display == nil)
        var display = LibraryDisplayOptions()
        precondition(display.contains(path: "/photos/child/a.png", folder: "/photos"))
        precondition(!display.contains(path: "/photos-other/a.png", folder: "/photos"))
        display.includeSubfolders = false
        precondition(display.contains(path: "/photos/a.png", folder: "/photos/"))
        precondition(!display.contains(path: "/photos/child/a.png", folder: "/photos"))
        precondition(!display.contains(path: nil, folder: "/photos"))
        precondition(display.thumbnailSize == LibraryDisplayOptions.defaultThumbnailSize)
        display.thumbnailSize = 10
        precondition(display.imageHeight == LibraryDisplayOptions.minimumThumbnailSize)
        display.thumbnailSize = 680
        precondition(display.imageHeight == LibraryDisplayOptions.maximumThumbnailSize)
        precondition(display.previewMaximumDimension == 1_536)
        precondition(display.galleryPreviewMaximumDimension == 512, "Large cards must not trigger screen-preview generation")
        let defaultCardPresentation = display.galleryCardPresentationIdentity
        display.showName = false
        precondition(display.galleryCardPresentationIdentity != defaultCardPresentation, "Hiding a name must reconfigure visible gallery cards")
        let nameHiddenPresentation = display.galleryCardPresentationIdentity
        display.showSummary = false
        precondition(display.galleryCardPresentationIdentity != nameHiddenPresentation, "Hiding a summary must reconfigure visible gallery cards")
        display.thumbnailSize = 240; display.showName = false; display.showSidebar = false
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"]!)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let session = LibrarySession(qaRoot: root)
        await session.start()
        guard session.error == nil else { fatalError(session.error!) }
        precondition(session.projectWorkspace == nil, "Asset manager must never start project scanning or AI queues")
        precondition(AppProduct.resolve(nil) == .assets && AppProduct.resolve("story") == .story)
        precondition(AppProduct.assets.applicationSupportRoot != AppProduct.story.applicationSupportRoot, "Installed products must not share writable settings/CLI roots")
        let storyRoot = root.appendingPathComponent("IndependentStory")
        let storySession = LibrarySession(qaRoot: storyRoot, product: .story, projectEventMonitoring: false)
        await storySession.start()
        precondition(storySession.error == nil && storySession.projectWorkspace != nil, "Story app owns its project service")
        precondition(storySession.root != session.root && storySession.applicationSupportRoot != session.applicationSupportRoot, "Separate registries, writable databases and CLI directories")
        precondition(storySession.store?.materials.isEmpty == true, "A new story app must not migrate the asset catalog into its own database")
        storySession.projectWorkspace?.stop()
        print("PRODUCT SPLIT PASS: assets has no project worker; story has independent registry/database/CLI root and no asset-catalog migration")
        var roots: [URL] = []
        for name in ["A", "B", "C"] {
            let url = root.appendingPathComponent(name + ".assetframelibrary")
            _ = try await LibraryTransfer.create(at: url, name: name, snapshot: MaterialSnapshot(materials: [], links: []))
            roots.append(url)
        }
        let a = Task { await session.open(roots[0]) }
        let b = Task { await session.open(roots[1]) }
        let c = Task { await session.open(roots[2]) }
        await a.value; await b.value; await c.value
        precondition(session.descriptor?.name == "C", "Stale switch won")
        session.browse.display = display
        session.browse.scrollY = 480; session.browse.search = "abc"
        await session.open(roots[0])
        precondition(session.browse.display == nil, "Display preferences leaked across libraries")
        await session.open(roots[2])
        precondition(session.browse.display == display, "Display preferences failed to restore")
        precondition(session.browse.scrollY == 480 && session.browse.search == "abc")
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for n in 0..<300 { try Data("not image".utf8).write(to: source.appendingPathComponent("\(n).png")) }
        let old = session.store!
        session.importURLs([source])
        await session.open(roots[0])
        try await Task.sleep(for: .milliseconds(100))
        precondition(!old.isImporting, "Import restarted in inactive session")
        precondition(session.store!.materials.isEmpty, "Imported into another library")
        let deleteFile = root.appendingPathComponent("delete-fixture.txt")
        try Data("Only a disposable self-test file".utf8).write(to: deleteFile)
        session.importURLs([deleteFile])
        while session.store!.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        let store = session.store!
        let record = store.materials.first { $0.sourcePath == deleteFile.path }!
        let original = try await store.committedLibrary()
        do { _ = try MaterialTrashService.paths(for: [record.id], in: original); preconditionFailure("Live record deletion allowed") } catch { }
        store.batchUpdate([record.id]) { $0.deletedAt = .now }
        _ = await store.saveNow()
        precondition(fm.fileExists(atPath: deleteFile.path), "Soft trash touched original file")
        let trashed = try await store.committedLibrary()
        var shared = trashed; var duplicate = record; duplicate.id = "shared"; shared.materials.append(duplicate)
        do { _ = try MaterialTrashService.paths(for: [record.id], in: shared); preconditionFailure("Shared source deletion allowed") } catch { }
        store.update(record.id) { $0.note = "Keep concurrent edit" }; _ = await store.saveNow()
        do { try await store.replaceLibrary(original, expected: trashed); preconditionFailure("Stale replacement overwrote edit") } catch { }
        precondition(store.materials.first?.note == "Keep concurrent edit")
        await session.deleteTrashedMaterials([record.id])
        precondition(session.error == nil, session.error ?? "")
        precondition(!fm.fileExists(atPath: deleteFile.path) && store.materials.isEmpty, "Deletion must remove record and move fixture source")
        // Return our own fixture from system Trash so the self-test leaves no trash behind.
        for url in try fm.contentsOfDirectory(at: session.root!, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("delete-recovery-") && url.pathExtension == "json" {
            let moves = try JSONDecoder().decode([MaterialTrashService.Move].self, from: Data(contentsOf: url))
            for move in moves { try fm.moveItem(atPath: move.destination, toPath: move.source) }
        }
        let removedLibraryRoot = session.root!
        let removedLibraryID = session.descriptor!.id
        let inactive = roots[2]
        let inactiveID = try LibraryDescriptor.read(inactive).id
        await session.removeRegisteredLibrary(inactiveID)
        precondition(session.descriptor?.id == removedLibraryID, "Removing inactive registration switched the current library")
        precondition(fm.fileExists(atPath: inactive.appendingPathComponent("global-material-library.sqlite").path), "Inactive removal deleted database")
        precondition(!session.registry.locations.contains { $0.id == inactiveID })
        await session.open(inactive)
        await session.open(removedLibraryRoot)
        // Remove only our disposable fixture directory to simulate an offline registration.
        try fm.removeItem(at: inactive)
        await session.removeRegisteredLibrary(inactiveID)
        precondition(session.error == nil && session.descriptor?.id == removedLibraryID)
        let offlineRemovalRegistry = try LibraryRegistry.read(root)
        precondition(!offlineRemovalRegistry.locations.contains { $0.id == inactiveID })
        await session.removeRegisteredLibrary("unregistered-id")
        precondition(session.descriptor?.id == removedLibraryID)
        await session.removeCurrentLibrary()
        precondition(session.error == nil, session.error ?? "")
        precondition(!session.registry.locations.contains(where: { $0.id == removedLibraryID }), "Removed library remained registered")
        precondition(fm.fileExists(atPath: removedLibraryRoot.path), "Removing a library registration must preserve its directory and database")
        precondition(session.descriptor?.id != removedLibraryID, "Removing the current library must switch to a remaining library")
        let persistedRegistry = try LibraryRegistry.read(root)
        precondition(!persistedRegistry.locations.contains(where: { $0.id == removedLibraryID }), "Library removal was not persisted")
        let lifetimeRoot = root.appendingPathComponent("Lifetime.assetframelibrary")
        _ = try await LibraryTransfer.create(at: lifetimeRoot, name: "Lifetime", snapshot: MaterialSnapshot(materials: [], links: []))
        var disposable: LibrarySession? = LibrarySession(qaRoot: root.appendingPathComponent("LifetimeSettings"))
        weak var weakSession = disposable
        await disposable!.open(lifetimeRoot)
        precondition(disposable!.error == nil)
        weak var weakStore = disposable!.store
        _ = await disposable!.store!.pauseSession()
        disposable = nil
        for _ in 0..<20 where weakSession != nil || weakStore != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(weakSession == nil && weakStore == nil, "Discarded sessions and stores must be released")
        do { let reclaimedLease = try LibraryWriteLease(lifetimeRoot); withExtendedLifetime(reclaimedLease) {} }
        var filterA = MaterialSearchFilter(), filterB = MaterialSearchFilter()
        filterA.requiredTags = Set(["z", "a"]); filterB.requiredTags = Set(["a", "z"])
        filterA.kinds = [.image, .video]; filterB.kinds = [.video, .image]
        precondition(LibraryScrollAnchor.filterIdentity(filterA) == LibraryScrollAnchor.filterIdentity(filterB))
        filterB.minimumRating = 3
        precondition(LibraryScrollAnchor.filterIdentity(filterA) != LibraryScrollAnchor.filterIdentity(filterB))
        var anchored = LibraryBrowseState()
        anchored.scrollAnchor = LibraryScrollAnchor(materialID: "stable-material", offset: 17.5, navigationIdentity: "all")
        let roundTrip = try JSONDecoder().decode(LibraryBrowseState.self, from: JSONEncoder().encode(anchored))
        precondition(roundTrip.scrollAnchor == anchored.scrollAnchor)
        let finished = await LibrarySession.finishBeforeTermination()
        precondition(finished)
        print("LibrarySessionSelfTest passed: rapid switches, browse restore, import-switch isolation, soft trash, shared-file protection, stale-edit protection, file deletion and recovery, safe library removal, weak session/store release, lease reclaim, item anchor round trip, flush")
    }
}
