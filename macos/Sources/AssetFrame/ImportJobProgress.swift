import Foundation

struct ImportJobProgress: Sendable {
    var id: UUID
    var sequence: UInt64 = 0
    var stage: String
    var discovered = 0
    var registered = 0
    var skipped = 0
    var failed = 0
    var scanCompleted = false
    var estimatedRemainingSeconds: Double?
    var startedAt = Date.now
    var lastAdvancedAt = Date.now
    var finished = false

    mutating func advance(stage: String, discovered: Int, registered: Int, skipped: Int, failed: Int, scanCompleted: Bool, finished: Bool) {
        guard !self.finished else { return }
        if self.discovered != discovered || self.registered != registered || self.skipped != skipped || self.failed != failed {
            lastAdvancedAt = .now
        }
        sequence &+= 1
        self.stage = stage
        self.discovered = discovered
        self.registered = registered
        self.skipped = skipped
        self.failed = failed
        self.scanCompleted = scanCompleted
        self.finished = finished
    }
    func waiting(at now: Date) -> Bool { !finished && now.timeIntervalSince(lastAdvancedAt) >= 10 }
}
