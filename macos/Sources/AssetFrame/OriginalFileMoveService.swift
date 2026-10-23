import Foundation

struct OriginalFileMoveResult: Equatable, Sendable {
    let sourceURL: URL
    let destinationURL: URL

    var wasRenamed: Bool { sourceURL.lastPathComponent != destinationURL.lastPathComponent }
}

enum OriginalFileMoveService {
    static func move(
        sourceURL: URL,
        destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> OriginalFileMoveResult {
        let source = sourceURL.standardizedFileURL
        let directory = destinationDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path),
              fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        let proposed = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        if proposed.standardizedFileURL == source {
            return OriginalFileMoveResult(sourceURL: source, destinationURL: source)
        }
        let destination = uniqueDestination(for: proposed, fileManager: fileManager)
        try fileManager.moveItem(at: source, to: destination)
        return OriginalFileMoveResult(sourceURL: source, destinationURL: destination)
    }

    private static func uniqueDestination(for proposed: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let fileExtension = proposed.pathExtension
        let baseName = proposed.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let filename = fileExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(fileExtension)"
            let candidate = directory.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
