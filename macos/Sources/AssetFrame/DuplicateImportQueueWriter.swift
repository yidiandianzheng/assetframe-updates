import Foundation

actor DuplicateImportQueueWriter {
    private var latestRevisionByManifest: [String: UInt64] = [:]

    func write(candidates: [DuplicateImportCandidate], to manifest: URL, revision: UInt64) {
        let key = manifest.standardizedFileURL.path
        guard revision >= latestRevisionByManifest[key, default: 0] else { return }
        latestRevisionByManifest[key] = revision

        do {
            try FileManager.default.createDirectory(
                at: manifest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(candidates).write(to: manifest, options: .atomic)
        } catch {
            // The in-memory queue remains intact and a later mutation retries the save.
        }
    }
}
