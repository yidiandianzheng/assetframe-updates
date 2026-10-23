import Foundation

@main
struct LinkedFolderUpdateDetectorSelfTest {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("folder-detect-\(UUID())").standardizedFileURL.resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: old)
        let values = try old.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let known = [LinkedFolderFileState(path: old.path, size: values.fileSize.map(Int64.init), modified: values.contentModificationDate?.addingTimeInterval(0.000_000_2))]
        let unchanged = await LinkedFolderUpdateDetector.scan(roots: [root, child], known: known)
        precondition(!unchanged.hasUpdates)
        let added = child.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: added)
        try Data("OLD".utf8).write(to: old)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(2)], ofItemAtPath: old.path)
        let updates = await LinkedFolderUpdateDetector.scan(roots: [root, child], known: known)
        precondition(updates.added.map(\.standardizedFileURL.path) == [added.path])
        precondition(updates.changed.map(\.standardizedFileURL.path) == [old.path])
        let oldData = try Data(contentsOf: old)
        let addedData = try Data(contentsOf: added)
        precondition(oldData == Data("OLD".utf8))
        precondition(addedData == Data("new".utf8))
        let missing = await LinkedFolderUpdateDetector.scan(roots: [root.appendingPathComponent("offline")], known: [])
        precondition(!missing.errors.isEmpty)
        let dependencies = root.appendingPathComponent("node_modules/package")
        let caches = root.appendingPathComponent("__pycache__")
        let export = root.appendingPathComponent("dist")
        for directory in [dependencies, caches, export] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let dependencyImage = dependencies.appendingPathComponent("icon.png")
        let cacheFile = caches.appendingPathComponent("cache.pyc")
        let exportedImage = export.appendingPathComponent("final.png")
        try Data("dependency".utf8).write(to: dependencyImage)
        try Data("cache".utf8).write(to: cacheFile)
        try Data("exported".utf8).write(to: exportedImage)
        try fm.createSymbolicLink(at: dependencies.appendingPathComponent("missing-dependency"), withDestinationURL: root.appendingPathComponent("does-not-exist"))
        let filtered = await LinkedFolderUpdateDetector.scan(roots: [root], known: [])
        let discoveredPaths = Set(filtered.added.map { $0.standardizedFileURL.path })
        print("DISCOVERY_PATHS \(discoveredPaths.sorted()) expected_export=\(exportedImage.standardizedFileURL.path)")
        precondition(!discoveredPaths.contains(dependencyImage.standardizedFileURL.path) && !discoveredPaths.contains(cacheFile.standardizedFileURL.path))
        precondition(discoveredPaths.contains(exportedImage.standardizedFileURL.path), "Generic export/dist directories must remain discoverable")
        precondition(filtered.errors.isEmpty, "Untracked dependency symlinks must not create library warnings")

        let dependencyValues = try dependencyImage.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let trackedDependency = [LinkedFolderFileState(path: dependencyImage.path, size: dependencyValues.fileSize.map(Int64.init), modified: dependencyValues.contentModificationDate)]
        let trackedUnchanged = await LinkedFolderUpdateDetector.scan(roots: [root], known: trackedDependency)
        precondition(!trackedUnchanged.changed.map(\.standardizedFileURL.path).contains(dependencyImage.standardizedFileURL.path))
        try Data("dependency-changed".utf8).write(to: dependencyImage)
        let trackedChanged = await LinkedFolderUpdateDetector.scan(roots: [root], known: trackedDependency)
        precondition(trackedChanged.changed.map(\.standardizedFileURL.path).contains(dependencyImage.standardizedFileURL.path), "Already indexed files must still report changes")
        let explicit = await LinkedFolderUpdateDetector.scan(roots: [root, root.appendingPathComponent("node_modules")], known: [])
        precondition(explicit.added.map(\.standardizedFileURL.path).contains(dependencyImage.standardizedFileURL.path), "Explicitly linked dependency roots must override automatic exclusion")

        // Default importer behavior remains unchanged; only the detector opts in.
        let directScanner = ImportDirectoryScanner(urls: [dependencies])
        let direct = await directScanner.next(first: true)
        precondition(direct.files.map(\.standardizedFileURL.path).contains(dependencyImage.standardizedFileURL.path))
        let sourceBytes = try Data(contentsOf: exportedImage)
        precondition(sourceBytes == Data("exported".utf8))
        print("LinkedFolderUpdateDetectorSelfTest passed: read-only discovery, deduplication, dates, additions, changes, offline roots, dependency exclusions, tracked-file changes, explicit roots, export folders and default import")
    }
}
