import Foundation

struct ImportResumeRecord: Codable, Sendable {
    var id: UUID
    var paths: [String]
    var projectID: String?
    var localFolder: LocalFolderSource?
    var audioOnly: Bool = false
    var createdAt = Date.now

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func clear(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func availableLocally(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
        return values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
    }
}

enum ImportContentReadGate {
    static let hashLock = NSLock()
}
