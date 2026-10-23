import Foundation

enum AssetFrameQADataRootError: LocalizedError {
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "ASSETFRAME_QA_DATA_ROOT 必须是系统临时目录中的 assetframe-qa.* 隔离目录：\(path)"
        }
    }
}

enum AssetFrameQADataRoot {
    static let environmentKey = "ASSETFRAME_QA_DATA_ROOT"
    static let managedFiveStarDirectoryName = "ManagedFiveStar"

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        guard let rawValue = environment[environmentKey], !rawValue.isEmpty else { return nil }
        let root = URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let allowedParents = Set([temporary.path, "/private/tmp", "/tmp"])
        let parentMatches = allowedParents.contains(root.deletingLastPathComponent().path)
        guard parentMatches, root.lastPathComponent.hasPrefix("assetframe-qa.") else {
            throw AssetFrameQADataRootError.invalidPath(root.path)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(managedFiveStarDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }
}

struct QAPendingSourceTrashService: PendingSourceTrashing {
    let allowedRoot: URL

    func moveToTrash(_ url: URL) throws {
        let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.trashItem(at: candidate, resultingItemURL: nil)
    }
}
