import Foundation

/// Operates only on recognized, reproducible cache entries. Maintenance is
/// triggered by use, with no timer or separately installed background service.
final class PreviewCacheBudget: @unchecked Sendable {
    struct Report: Codable, Sendable {
        var byteBudget: Int64
        var reserveBytes: Int64
        var observedBytes: Int64 = 0
        var removedFiles = 0
        var skippedWrites = 0
        var truncated = false
        var checked = false
        var scanning = false
        var visitedFiles = 0
        var scanChunks = 0
        var limitReached = false
        var readErrors = 0
    }
    static let shared = PreviewCacheBudget()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "AssetFrame.cache-budget", qos: .utility)
    private var report: Report
    private var lastCheck: [String: Date] = [:]
    private var scheduled: Set<String> = []
    private var accesses: [String: Date] = [:]
    private var reportRoot = ""
    private var interactionTime: UInt64 = 0
    private var writeGrowth: [String: Int64] = [:]
    private let chunkItemLimit: Int
    private let chunkSeconds: Double
    private let initialDelaySeconds: Double
    init(byteBudget: Int64 = 1024 * 1024 * 1024, reserveBytes: Int64 = 2 * 1024 * 1024 * 1024, chunkItemLimit: Int = 128, chunkSeconds: Double = 0.04, initialDelaySeconds: Double = 3) {
        report = Report(byteBudget: max(0, byteBudget), reserveBytes: max(0, reserveBytes))
        self.chunkItemLimit = max(1, chunkItemLimit)
        self.chunkSeconds = max(0.001, chunkSeconds)
        self.initialDelaySeconds = max(0, initialDelaySeconds)
    }
    func snapshot(root: URL) -> Report {
        lock.lock(); defer { lock.unlock() }
        var value = report
        if reportRoot != root.path {
            value.observedBytes = 0; value.checked = false; value.scanning = false
            value.truncated = false; value.visitedFiles = 0; value.scanChunks = 0; value.limitReached = false; value.readErrors = 0
        }
        return value
    }
    private static let extensions: [String: String] = ["Thumbnails": "png", "ScreenPreviews": "png", "MediaThumbnails": "tiff", "MediaAnalysis": "json", "SimilarityHashes": "json"]
    static func recognized(_ file: URL, root: URL) -> Bool {
        let parent = file.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              extensions[parent.lastPathComponent] == file.pathExtension else { return false }
        let key = file.deletingPathExtension().lastPathComponent
        return key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func allowWrite(bytes: Int, file: URL, root: URL, freeBytes: Int64?, replacingBytes: Int = 0) -> Bool {
        guard Self.recognized(file, root: root), bytes >= 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        let tooLarge = Int64(bytes) > report.byteBudget
        let lowSpace = freeBytes.map { $0 - Int64(bytes) < report.reserveBytes } ?? false
        // The estimate may include the replaced file; conservatively skip when full.
        let full = reportRoot == root.path && report.checked && report.observedBytes + Int64(max(0, bytes - replacingBytes)) > report.byteBudget
        if tooLarge || lowSpace || full { report.skippedWrites += 1; return false }
        return true
    }
    func didWrite(bytes: Int, root: URL) {
        lock.lock(); defer { lock.unlock() }
        if writeGrowth.count > 32 { writeGrowth = writeGrowth.filter { $0.key == root.path || scheduled.contains($0.key) } }
        writeGrowth[root.path, default: 0] += Int64(max(0, bytes))
        if reportRoot == root.path { report.observedBytes += Int64(max(0, bytes)) }
    }
    func touch(_ file: URL, root: URL) {
        guard Self.recognized(file, root: root) else { return }
        lock.lock()
        let now = Date()
        let due = accesses[file.path].map { now.timeIntervalSince($0) >= 60 } ?? true
        if due {
            if accesses.count >= 2048 { accesses.removeAll(keepingCapacity: true) }
            accesses[file.path] = now
        }
        lock.unlock()
        guard due else { return }
        queue.async {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink == false,
                  file.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { return }
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
    }
    func noteInteraction() {
        lock.lock(); interactionTime = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }
    private func recentlyBrowsing() -> Bool {
        lock.lock(); let stamp = interactionTime; lock.unlock()
        return stamp > 0 && DispatchTime.now().uptimeNanoseconds - stamp < 250_000_000
    }
    private struct Entry { var url: URL; var bytes: Int64; var date: Date }
    private final class Sweep: @unchecked Sendable {
        let root: URL
        let canonical: URL
        let startWriteGrowth: Int64
        let categories = PreviewCacheBudget.extensions.keys.sorted()
        var folderIndex = 0
        var walk: FileManager.DirectoryEnumerator?
        var entries: [Entry] = []
        var total: Int64 = 0
        var visited = 0
        var chunks = 0
        var complete = false
        var limitReached = false
        var ordered: [Entry]?
        var retireIndex = 0
        var retiredCount = 0
        var readErrors = 0
        init(root: URL, startWriteGrowth: Int64) {
            self.root = root; self.canonical = root.resolvingSymlinksInPath()
            self.startWriteGrowth = startWriteGrowth
        }
    }
    private func newSweep(_ root: URL) -> Sweep {
        lock.lock(); let growth = writeGrowth[root.path] ?? 0; lock.unlock()
        return Sweep(root: root, startWriteGrowth: growth)
    }
    func schedule(root: URL, isCurrent: @escaping @Sendable () -> Bool) {
        lock.lock()
        let now = Date()
        let due = lastCheck[root.path].map { now.timeIntervalSince($0) >= 60 } ?? true
        guard due, !scheduled.contains(root.path) else { lock.unlock(); return }
        if lastCheck.count >= 32 { lastCheck.removeAll() }
        scheduled.insert(root.path); lastCheck[root.path] = now
        lock.unlock()
        let sweep = newSweep(root)
        queue.asyncAfter(deadline: .now() + initialDelaySeconds) { [self] in run(sweep, isCurrent: isCurrent) }
    }
    private func run(_ sweep: Sweep, isCurrent: @escaping @Sendable () -> Bool) {
        guard isCurrent() else { finishScheduled(sweep, checked: false); return }
        if recentlyBrowsing() {
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in run(sweep, isCurrent: isCurrent) }
            return
        }
        readChunk(sweep)
        publish(sweep, checked: false, scanning: !sweep.complete && !sweep.limitReached)
        if sweep.limitReached || (sweep.complete && sweep.readErrors > 0) { finishScheduled(sweep, checked: false); return }
        if !sweep.complete {
            queue.asyncAfter(deadline: .now() + 0.03) { [self] in run(sweep, isCurrent: isCurrent) }
            return
        }
        if retireChunk(sweep, isCurrent: isCurrent, allowEviction: true) {
            publish(sweep, checked: isCurrent(), scanning: false, removed: sweep.retiredCount)
            finishScheduled(sweep, checked: isCurrent())
        } else {
            publish(sweep, checked: false, scanning: true)
            queue.asyncAfter(deadline: .now() + 0.03) { [self] in run(sweep, isCurrent: isCurrent) }
        }
    }
    private func readChunk(_ sweep: Sweep) {
        let fm = FileManager.default, deadline = Date().addingTimeInterval(chunkSeconds)
        var chunkVisited = 0
        sweep.chunks += 1
        while chunkVisited < chunkItemLimit && Date() < deadline {
            if sweep.visited >= 250_000 { sweep.limitReached = true; return }
            if sweep.walk == nil {
                guard sweep.folderIndex < sweep.categories.count else { sweep.complete = true; return }
                let folder = sweep.root.appendingPathComponent(sweep.categories[sweep.folderIndex], isDirectory: true)
                sweep.folderIndex += 1
                let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values == nil && fm.fileExists(atPath: folder.path) { sweep.readErrors += 1 }
                guard values?.isDirectory == true, values?.isSymbolicLink == false,
                      folder.resolvingSymlinksInPath().deletingLastPathComponent().path == sweep.canonical.path else { continue }
                sweep.walk = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey], errorHandler: { _, _ in sweep.readErrors += 1; return true })
                if sweep.walk == nil { sweep.readErrors += 1; continue }
            }
            guard let file = sweep.walk?.nextObject() as? URL else { sweep.walk = nil; continue }
            sweep.visited += 1; chunkVisited += 1
            guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                if fm.fileExists(atPath: file.path), Self.recognized(file, root: sweep.root) { sweep.readErrors += 1 }
                continue
            }
            if v.isSymbolicLink == true || v.isDirectory == true { sweep.walk?.skipDescendants(); continue }
            guard v.isRegularFile == true, Self.recognized(file, root: sweep.root) else { continue }
            let bytes = Int64(v.fileSize ?? 0); sweep.total += bytes
            sweep.entries.append(Entry(url: file, bytes: bytes, date: v.contentModificationDate ?? .distantPast))
        }
    }
    private func publish(_ sweep: Sweep, checked: Bool, scanning: Bool, removed: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        // Writes occurring during enumeration may already be counted. Include
        // their growth conservatively rather than under-reporting a new entry.
        let growth = max(0, (writeGrowth[sweep.root.path] ?? 0) - sweep.startWriteGrowth)
        reportRoot = sweep.root.path; report.observedBytes = sweep.total + growth
        report.removedFiles += removed; report.truncated = !checked
        report.checked = checked; report.scanning = scanning
        report.visitedFiles = sweep.visited; report.scanChunks = sweep.chunks
        report.limitReached = sweep.limitReached
        report.readErrors = sweep.readErrors
    }
    private func retireChunk(_ sweep: Sweep, isCurrent: @Sendable () -> Bool, allowEviction: Bool) -> Bool {
        guard sweep.complete, !sweep.limitReached, sweep.readErrors == 0, isCurrent() else { return true }
        let budget = snapshot(root: sweep.root).byteBudget * 9 / 10
        guard allowEviction, sweep.total > budget else { return true }
        if sweep.ordered == nil {
            guard sweep.total > snapshot(root: sweep.root).byteBudget else { return true }
            sweep.ordered = sweep.entries.sorted(by: { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date < $1.date })
        }
        let deadline = Date().addingTimeInterval(chunkSeconds)
        var visited = 0
        while sweep.total > budget && sweep.retireIndex < sweep.ordered!.count && visited < chunkItemLimit && Date() < deadline {
            guard isCurrent() else { return true }
            let entry = sweep.ordered![sweep.retireIndex]; sweep.retireIndex += 1; visited += 1
            let fresh = try? entry.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            lock.lock(); let access = accesses[entry.url.path]; lock.unlock()
            guard fresh?.isRegularFile == true, fresh?.isSymbolicLink == false,
                  Int64(fresh?.fileSize ?? -1) == entry.bytes,
                  fresh?.contentModificationDate == entry.date,
                  access == nil || access! <= entry.date,
                  entry.url.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path == sweep.canonical.path else { continue }
            do { try FileManager.default.removeItem(at: entry.url); sweep.total -= entry.bytes; sweep.retiredCount += 1 } catch { continue }
        }
        return sweep.total <= budget || sweep.retireIndex >= sweep.ordered!.count
    }
    private func finishScheduled(_ sweep: Sweep, checked: Bool) {
        if !checked { publish(sweep, checked: false, scanning: false) }
        lock.lock(); scheduled.remove(sweep.root.path); lastCheck[sweep.root.path] = Date(); lock.unlock()
    }
    /// Full traversal for tests and explicit diagnostics. Call only off the UI
    /// thread; production scheduling uses resumable chunks and browsing pauses.
    @discardableResult func maintain(root: URL, isCurrent: @Sendable () -> Bool = { true }, allowEviction: Bool = true) -> Report {
        let sweep = newSweep(root)
        while !sweep.complete && !sweep.limitReached && isCurrent() { readChunk(sweep) }
        if sweep.complete && !sweep.limitReached && sweep.readErrors == 0 && isCurrent() {
            while !retireChunk(sweep, isCurrent: isCurrent, allowEviction: allowEviction) && isCurrent() { }
            publish(sweep, checked: isCurrent(), scanning: false, removed: sweep.retiredCount)
        } else { publish(sweep, checked: false, scanning: false) }
        return snapshot(root: root)
    }
}
