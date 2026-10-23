import Foundation

/// A browse-time observation, never a deletion or a persisted business field.
enum MaterialSourceAvailability: String, Sendable {
    case available = ""
    case missing = "原文件已失联"
    case offline = "磁盘离线"
    case cloudOnly = "云端文件尚未下载"
    case unreadable = "原文件暂时无法读取"

    /// A legacy material can retain more than one known source. Treat it as
    /// missing only when every usable path is confirmed missing.
    static func inspect(paths: [String?]) -> Self {
        let statuses = paths.compactMap { path -> Self? in
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return inspect(path: path)
        }
        guard !statuses.isEmpty else { return .missing }
        if statuses.contains(.available) { return .available }
        if statuses.contains(.unreadable) { return .unreadable }
        if statuses.contains(.cloudOnly) { return .cloudOnly }
        if statuses.contains(.offline) { return .offline }
        return .missing
    }

    static func inspect(path: String?) -> Self {
        guard let path, !path.isEmpty else { return .missing }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parts = url.pathComponents
        if parts.count > 2, parts[1] == "Volumes",
           !fm.fileExists(atPath: "/Volumes/" + parts[2]) { return .offline }
        // File Provider may expose only a placeholder. That is not deletion.
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if fm.fileExists(atPath: placeholder.path) { return .cloudOnly }
        do {
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current,
               values.ubiquitousItemDownloadingStatus != .downloaded { return .cloudOnly }
            // resourceValues can succeed with an empty dictionary for a deleted URL.
            // attributesOfItem distinguishes ENOENT from permission failures.
            _ = try fm.attributesOfItem(atPath: path)
            return fm.isReadableFile(atPath: path) ? .available : .unreadable
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return .missing }
            return .unreadable
        }
    }
}
