import Foundation

struct LinkedFolderFileState: Sendable {
    var path: String
    var size: Int64?
    var modified: Date?
}

struct LinkedFolderUpdates: Sendable {
    var added: [URL] = []
    var changed: [URL] = []
    var directories: [URL] = []
    var errors: [String] = []
    var skipped: [String] = []
    var signature = ""
    var hasUpdates: Bool { !added.isEmpty || !changed.isEmpty }
}

/// Read-only, bounded directory discovery. No files are copied, hashed or indexed.
enum LinkedFolderUpdateDetector {
    // Only automatic discovery skips dependency/cache descendants. Explicit
    // import retains its original scanner policy; an explicitly linked root
    // also wins over a containing root's exclusions.
    private static let ignoredDiscoveryDirectories: Set<String> = [
        "node_modules", "__pycache__", ".git", ".hg", ".svn", ".build", ".swiftpm", ".venv"
    ]

    private static func isIgnoredDiscoveryPath(_ path: String, roots: [String]) -> Bool {
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }),
              path != root else { return false }
        let relative = path.dropFirst(root.count + (root == "/" ? 0 : 1))
        return relative.split(separator: "/").contains { ignoredDiscoveryDirectories.contains(String($0)) }
    }

    static func scan(roots: [URL], known: [LinkedFolderFileState]) async -> LinkedFolderUpdates {
        let byPath = Dictionary(grouping: known, by: { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let rootPaths = roots.map { $0.standardizedFileURL.path }.sorted { $0.count > $1.count }
        let scanner = ImportDirectoryScanner(urls: roots, qos: .utility) { url in
            guard isIgnoredDiscoveryPath(url.standardizedFileURL.path, roots: rootPaths) else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        // Skipping untracked dependencies must not stop monitoring files the
        // user already added to the library. Check just those known paths.
        var trackedInIgnoredDirectories = byPath.keys.filter {
            isIgnoredDiscoveryPath($0, roots: rootPaths)
        }.sorted().map { URL(fileURLWithPath: $0) }
        var result = LinkedFolderUpdates()
        var seen = Set<String>()
        var signatures: [String] = []
        var first = true
        while !Task.isCancelled {
            let batch = await scanner.next(first: first)
            first = false
            result.directories += batch.directories
            result.skipped += batch.errors.filter { $0.contains("不支持的文件类型") }
            result.errors += batch.errors.filter { !$0.contains("不支持的文件类型") }
            let files = batch.files + trackedInIgnoredDirectories
            trackedInIgnoredDirectories.removeAll()
            for url in files {
                guard !Task.isCancelled else { return result }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values.fileSize.map(Int64.init)
                    let modified = values.contentModificationDate
                    if let records = byPath[path] {
                        let matches = records.contains { old in
                            guard old.size == size, let oldDate = old.modified, let modified else { return false }
                            return abs(oldDate.timeIntervalSince(modified)) <= 0.000_001
                        }
                        if matches { continue }
                        result.changed.append(url)
                    } else { result.added.append(url) }
                    signatures.append("\(path)|\(size ?? -1)|\(modified?.timeIntervalSince1970.description ?? "unknown")")
                } catch { result.errors.append("\(path): \(error.localizedDescription)") }
            }
            if batch.finished { break }
        }
        result.added.sort { $0.path < $1.path }
        result.changed.sort { $0.path < $1.path }
        result.signature = (signatures + result.errors).sorted().joined(separator: "\n")
        return result
    }
}
