import Foundation

actor PendingImportJournalWriter {
    func append(_ items: [PendingImportItem], to url: URL) throws {
        guard !items.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = Data()
        for item in items {
            payload.append(try encoder.encode(item))
            payload.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()
    }

    func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func load(from url: URL) -> [PendingImportItem] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var identities = Set<String>()
        return data.split(separator: 0x0A).compactMap { line in
            guard let item = try? decoder.decode(PendingImportItem.self, from: Data(line)),
                  identities.insert(item.sourceIdentity).inserted else { return nil }
            return item
        }
    }
}
