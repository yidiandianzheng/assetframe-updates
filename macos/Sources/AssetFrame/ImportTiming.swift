import Foundation

/// Durations overlap; the total is wall time, never their sum.
final class ImportTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date.now
    private var seconds: [String: Double] = [:]
    private var firstPublished: Double?
    func record(_ phase: String, since start: Date) {
        lock.lock(); defer { lock.unlock() }
        seconds[phase, default: 0] += Date.now.timeIntervalSince(start)
    }
    func published() {
        lock.lock(); defer { lock.unlock() }
        if firstPublished == nil { firstPublished = Date.now.timeIntervalSince(started) }
    }
    func report(_ route: String) {
        lock.lock()
        var values = seconds
        values["wall_seconds"] = Date.now.timeIntervalSince(started)
        values["first_publication_seconds"] = firstPublished
        lock.unlock()
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            print("IMPORT_TIMING \(route) \(json)")
        }
    }
}
