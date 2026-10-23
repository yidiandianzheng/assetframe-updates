import Foundation

/// Exact content matches only. A filename never authorizes relinking a record.
enum MaterialRelocationScan {
    struct Candidate: Identifiable, Sendable {
        var materialID: String
        var path: String
        var id: String { materialID + "|" + path }
    }
    struct Result: Sendable {
        var candidates: [Candidate] = []
        var scannedFiles = 0
        var hashedFiles = 0
        var missingWithoutFingerprint = 0
        var truncated = false
    }
    static func scan(materials: [MaterialRecord], directory: URL) -> Result {
        var result = Result()
        let missing = materials.filter { record in
            guard record.deletedAt == nil, let path = record.sourcePath else { return false }
            return !FileManager.default.fileExists(atPath: path)
        }
        let verifiable = missing.filter { record in
            let value = record.contentFingerprint ?? record.fingerprint
            let valid = value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            if !valid { result.missingWithoutFingerprint += 1 }
            return valid && record.fileSize != nil
        }
        guard !verifiable.isEmpty else { return result }
        let bySize = Dictionary(grouping: verifiable, by: { $0.fileSize! })
        let canonical = directory.resolvingSymlinksInPath()
        guard let walk = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        let deadline = Date().addingTimeInterval(15)
        var readBytes: Int64 = 0
        for case let file as URL in walk {
            if Task.isCancelled { result.truncated = true; break }
            result.scannedFiles += 1
            if result.scannedFiles > 20_000 || Date() > deadline { result.truncated = true; break }
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            if info.isSymbolicLink == true { walk.skipDescendants(); continue }
            guard info.isRegularFile == true, let size = info.fileSize, let records = bySize[Int64(size)],
                  file.resolvingSymlinksInPath().path.hasPrefix(canonical.path + "/") else { continue }
            // Hash each plausible file once; never hash an entire SSD as a background scan.
            if readBytes + Int64(size) > 1024 * 1024 * 1024 || result.hashedFiles >= 256 { result.truncated = true; break }
            readBytes += Int64(size); result.hashedFiles += 1
            guard let hash = GlobalMaterialStore.streamFingerprint(file),
                  let after = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  after.fileSize == info.fileSize, after.contentModificationDate == info.contentModificationDate else { continue }
            for record in records where (record.contentFingerprint ?? record.fingerprint) == hash {
                result.candidates.append(Candidate(materialID: record.id, path: file.path))
            }
        }
        return result
    }
}
