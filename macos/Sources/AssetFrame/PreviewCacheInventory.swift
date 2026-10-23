import Foundation

struct PreviewCacheInventory: Codable, Sendable {
    var root: String
    var bytes: Int64 = 0
    var files = 0
    var categories: [String: Int64] = [:]
    var generations: [String: Int64] = [:]
    var truncated = false
    static func read(root inputRoot: URL) -> Self {
        let root = inputRoot.resolvingSymlinksInPath().standardizedFileURL
        var report = Self(root: root.path)
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return report }
        let deadline = Date().addingTimeInterval(2)
        var visited = 0
        for case let file as URL in walk {
            visited += 1
            if visited > 100_000 || Date() > deadline { report.truncated = true; break }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { walk.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let parts = path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
            guard parts.count >= 2 else { continue }
            let size = Int64(values.fileSize ?? 0)
            report.bytes += size; report.files += 1
            report.generations[parts[0], default: 0] += size
            report.categories[parts[1], default: 0] += size
        }
        return report
    }
}
