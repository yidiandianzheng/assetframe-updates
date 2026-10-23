import Foundation

struct ImportScanBatch: Sendable {
    var files: [URL] = []
    var directories: [URL] = []
    var errors: [String] = []
    var finished = false
}

/// Pull-based backpressure: no producer runs ahead of a committed batch.
/// At most 128 file descriptions are returned; directories count against the
/// same 256-entry work budget. All FileProvider work stays on a serial worker.
final class ImportDirectoryScanner: @unchecked Sendable {
    private let queue: DispatchQueue
    private var roots: [URL]
    private var rootIndex = 0
    private var enumerator: FileManager.DirectoryEnumerator?
    private var errors: [String] = []
    private let excluded: @Sendable (URL) -> Bool

    init(urls: [URL], qos: DispatchQoS.QoSClass = .userInitiated,
         excluded: @escaping @Sendable (URL) -> Bool = { _ in false }) {
        queue = DispatchQueue(label: "assetframe.import-scanner", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
        roots = urls
        self.excluded = excluded
    }

    func next(first: Bool) async -> ImportScanBatch {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.read(first: first)) }
        }
    }

    private func read(first: Bool) -> ImportScanBatch {
        var batch = ImportScanBatch()
        let deadline = Date.now.addingTimeInterval(first ? 0.2 : 0.5)
        var visited = 0
        while batch.files.count < (first ? 32 : 128), visited < 256 {
            if visited > 0, Date.now >= deadline { break }
            let url: URL
            if let enumerator {
                guard let child = enumerator.nextObject() as? URL else {
                    self.enumerator = nil
                    continue
                }
                url = child
            } else {
                guard rootIndex < roots.count else { batch.finished = true; break }
                url = roots[rootIndex]
                rootIndex += 1
            }
            visited += 1
            if excluded(url) { enumerator?.skipDescendants(); continue }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    batch.directories.append(url)
                    if enumerator == nil {
                        enumerator = FileManager.default.enumerator(
                            at: url,
                            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .fileResourceIdentifierKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants],
                            errorHandler: { failed, error in
                                self.errors.append("\(failed.path): \(error.localizedDescription)")
                                return true
                            })
                        if enumerator == nil { errors.append("无法读取目录：\(url.path)") }
                    }
                } else if values.isRegularFile == true { batch.files.append(url) }
                else { errors.append("不支持的文件类型：\(url.path)") }
            } catch { errors.append("\(url.path): \(error.localizedDescription)") }
        }
        batch.errors = errors
        errors.removeAll(keepingCapacity: true)
        return batch
    }
}
