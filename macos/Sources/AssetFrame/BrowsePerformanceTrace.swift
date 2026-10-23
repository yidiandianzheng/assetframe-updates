import AppKit
import Darwin
import Foundation

/// Local QA metrics. Main-loop ticks measure scheduling, not presented frames.
@MainActor enum BrowsePerformanceTrace {
    private static let qaRoot: URL? = {
        guard ProcessInfo.processInfo.environment["ASSETFRAME_PERF_TRACE"] == "1",
              let path = ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"] else { return nil }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let parents = ["/tmp", "/private/tmp", FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
        guard root.lastPathComponent.hasPrefix("assetframe-qa."),
              parents.contains(root.deletingLastPathComponent().path) else { return nil }
        return root
    }()
    static var enabled: Bool { qaRoot != nil }
    private static let writer: Writer? = qaRoot.flatMap { Writer(url: $0.appendingPathComponent("browse-metrics.jsonl")) }
    private static var selectionStart: UInt64?
    private static var previewStart: (id: String, time: UInt64)?
    private static var timer: Timer?
    private static var terminationObserver: NSObjectProtocol?
    private static var previousTick: UInt64 = 0
    private static var previousMemorySample: UInt64 = 0
    private static var samplingStart: UInt64 = 0
    private static var samplingFinished = false

    static func startSampling() {
        guard enabled, !samplingFinished, timer == nil else { return }
        previousTick = DispatchTime.now().uptimeNanoseconds
        samplingStart = previousTick
        previousMemorySample = 0
        record("session_start")
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { finish() } }
    }
    private static func sample() {
        let now = DispatchTime.now().uptimeNanoseconds
        // A diagnostic app must not keep recording indefinitely if the user
        // steps away or locks the screen during a measurement run.
        if now - samplingStart >= 180_000_000_000 { finish(); return }
        record("main_loop_tick", fields: ["interval_ms": Double(now - previousTick) / 1_000_000])
        previousTick = now
        if now - previousMemorySample >= 1_000_000_000 {
            previousMemorySample = now
            var info = mach_task_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                record("process_memory", fields: ["resident_mb": Double(info.resident_size) / 1_048_576])
            }
        }
    }
    static func finish() {
        guard enabled, !samplingFinished else { return }
        timer?.invalidate()
        timer = nil
        record("session_end")
        samplingFinished = true
        writer?.flush()
    }
    static func beginSelection() {
        if enabled { selectionStart = DispatchTime.now().uptimeNanoseconds }
    }
    static func completeSelection() {
        guard let start = selectionStart else { return }
        selectionStart = nil
        emit("selection_view_commit", since: start)
    }
    static func beginPreview(_ id: String) {
        if enabled { previewStart = (id, DispatchTime.now().uptimeNanoseconds) }
    }
    static func completePreview(_ id: String) {
        guard let start = previewStart, start.id == id else { return }
        previewStart = nil
        emit("preview_draw_complete", since: start.time)
    }
    static func emit(_ operation: String, since start: UInt64, fields: [String: Any] = [:]) {
        guard enabled, !samplingFinished else { return }
        var fields = fields
        fields["duration_ms"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        record(operation, fields: fields)
    }
    static func record(_ operation: String, fields: [String: Any] = [:]) {
        guard enabled, !samplingFinished else { return }
        var record = fields
        record["event"] = operation
        record["wall_time"] = Date.now.timeIntervalSince1970
        record["pid"] = ProcessInfo.processInfo.processIdentifier
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        writer?.append(data)
    }

    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "assetframe.qa-metrics", qos: .utility)
        private let handle: FileHandle
        init?(url: URL) {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
            self.handle = handle
            _ = try? handle.seekToEnd()
        }
        func append(_ data: Data) { queue.async { try? self.handle.write(contentsOf: data) } }
        func flush() { queue.sync { try? handle.synchronize() } }
        deinit { try? handle.close() }
    }
}
