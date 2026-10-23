import Foundation

actor PendingImportManifestWriter {
    private var latestRevisionByManifest: [String: UInt64] = [:]

    @discardableResult
    func write(
        items: [PendingImportItem],
        root: URL,
        directoryName: String,
        manifestName: String,
        revision: UInt64
    ) -> Bool {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        let manifest = directory.appendingPathComponent(manifestName)
        let key = manifest.standardizedFileURL.path
        guard revision >= latestRevisionByManifest[key, default: 0] else { return false }
        latestRevisionByManifest[key] = revision

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: manifest, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
