import Foundation

@main
struct UnifiedLibrarySelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-unified-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let originals = root.appendingPathComponent("Originals")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let files = (0..<3).map { originals.appendingPathComponent("图片-\($0).png") }
        for file in files { try png.write(to: file) }
        let readBytes = try LibraryTransfer.readLegacyMetadata(files[0])
        precondition(readBytes == png)
        let slowRead = DispatchSemaphore(value: 0)
        let began = Date()
        do {
            _ = try LibraryTransfer.readLegacyMetadata(files[0], timeout: 0.02) { _ in
                slowRead.wait(); return png
            }
            preconditionFailure("Stalled metadata read did not time out")
        } catch { precondition(Date().timeIntervalSince(began) < 1) }
        slowRead.signal()
        let legacyRoot = root.appendingPathComponent("Legacy")
        let legacy = AssetStore(rootURL: legacyRoot)
        while legacy.isLoadingProject { try await Task.sleep(for: .milliseconds(10)) }
        legacy.stageImages(files)
        while legacy.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        legacy.cancelBackgroundMetadata()
        _ = legacy.performSetRating(3, on: [.pending(legacy.pendingImports[0].id)])
        await legacy.flushPendingImportManifest(); await legacy.flushCurrentProject()
        let sourceDB = URL(fileURLWithPath: legacy.currentProject.databasePath)
        let sourceBytes = try Data(contentsOf: sourceDB)
        let migrated = try await LibraryTransfer.backupAndMigrate(root: legacyRoot)
        precondition(migrated.materials.count == 3, "Formal and pending imports must both migrate")
        precondition(migrated.materials.filter { $0.rating == 3 }.count == 1)
        precondition(migrated.links.count == 3)
        let originalPaths = Set(legacy.pendingImports.map(\.originalSourcePath))
        let retainedPaths = Set(migrated.materials.compactMap { $0.legacyAsset?.sourceOriginalPath })
        precondition(originalPaths.isSubset(of: retainedPaths), "Pending original provenance paths were lost")
        precondition(migrated.organization?.legacyPayloads.keys.contains(where: { $0.contains(":pending:") }) == true)

        let afterSourceBytes = try Data(contentsOf: sourceDB)
        precondition(afterSourceBytes == sourceBytes, "Migration must be read-only")
        let a = root.appendingPathComponent("A.assetframelibrary")
        let info = try await LibraryTransfer.create(at: a, name: "测试A", snapshot: migrated)
        let readInfo = try LibraryDescriptor.read(a)
        precondition(readInfo.id == info.id)
        let stored = try LibraryTransfer.readLibrary(a)
        precondition(stored.materials == migrated.materials)
        precondition(stored.organization == migrated.organization)
        var lease: LibraryWriteLease? = try LibraryWriteLease(a)
        do { _ = try LibraryWriteLease(a); preconditionFailure("Second writer accepted") } catch { }
        withExtendedLifetime(lease) { }; lease = nil
        let recoveredLease = try LibraryWriteLease(a)
        withExtendedLifetime(recoveredLease) { }
        var source = migrated
        source.materials[0].rating = 4
        let inputID = source.materials[1].id
        source.materials[0].production?.inputMaterialIDs = [inputID]
        let report = try LibraryTransfer.merge(source: source, sourceID: UUID().uuidString, into: migrated)
        precondition(report.conflicts >= 1)
        let sourceID = UUID().uuidString
        let first = try LibraryTransfer.merge(source: source, sourceID: sourceID, into: migrated)
        let second = try LibraryTransfer.merge(source: source, sourceID: sourceID, into: first.snapshot)
        precondition(first.snapshot.materials == second.snapshot.materials, "Repeated merge changed materials")
        precondition(first.snapshot.links == second.snapshot.links)
        var amended = source
        amended.materials[0].rating = 5
        let edited = try LibraryTransfer.merge(source: amended, sourceID: sourceID, into: first.snapshot)
        precondition(edited.added == 1, "Changed source revision must not be silently skipped")
        precondition(first.snapshot.materials.allSatisfy { old in edited.snapshot.materials.contains(old) }, "Existing material was overwritten")
        let editedAgain = try LibraryTransfer.merge(source: amended, sourceID: sourceID, into: edited.snapshot)
        precondition(editedAgain.snapshot.materials == edited.snapshot.materials)
        precondition(editedAgain.snapshot.links == edited.snapshot.links)
        let linkedIDs = Set(first.snapshot.materials.map(\.id))
        precondition(first.snapshot.links.allSatisfy { linkedIDs.contains($0.materialID) })
        precondition(first.snapshot.materials.flatMap { $0.production?.inputMaterialIDs ?? [] }.allSatisfy { linkedIDs.contains($0) })
        let b = root.appendingPathComponent("B.assetframelibrary")
        _ = try await LibraryTransfer.create(at: b, name: "测试B", snapshot: first.snapshot)
        let db = MaterialDatabase(root: b)
        var changed = try await db.load()
        let before = changed
        let removed = changed.links.removeFirst()
        try await db.commit(changed, previous: before)
        let restored = try await db.load()
        precondition(restored.materials == before.materials)
        precondition(!restored.links.contains(where: { $0.id == removed.id }))
        let unchanged = try LibraryTransfer.readLibrary(a)
        precondition(unchanged.materials == migrated.materials, "Independent library changed")
        var invalid = changed
        invalid.links.append(ProjectMaterialLink(id: UUID().uuidString, projectID: "p", materialID: "missing", use: .candidate, createdAt: .now))
        do { try await db.commit(invalid, previous: changed); preconditionFailure("Invalid reference accepted") } catch { }
        let afterFailure = try await db.load()
        precondition(afterFailure.materials == changed.materials)
        for file in files { let data = try Data(contentsOf: file); precondition(data == png) }
        print("UnifiedLibrarySelfTest passed: strict legacy migration, pending records, metadata, read-only source, writer lease, merge idempotency, references, isolation, transaction failure")
    }
}
