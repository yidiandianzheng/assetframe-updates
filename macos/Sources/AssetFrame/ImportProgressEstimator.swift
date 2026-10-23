import Foundation

/// Produces a stable, conservative ETA from throttled import progress samples.
/// The estimator deliberately waits for enough work and elapsed time before it
/// exposes a value so the UI does not show a wildly changing first estimate.
struct ImportProgressEstimator: Sendable {
    private var jobID: UUID?
    private var startedAt: Date = .distantPast
    private var lastSampleAt: Date = .distantPast
    private var lastProcessed = 0
    private var smoothedItemsPerSecond: Double?

    mutating func estimate(
        jobID: UUID,
        isActive: Bool,
        isCompleted: Bool,
        processed: Int,
        total: Int,
        at now: Date
    ) -> TimeInterval? {
        if self.jobID != jobID {
            self.jobID = jobID
            startedAt = now
            lastSampleAt = now
            lastProcessed = processed
            smoothedItemsPerSecond = nil
        }

        if isCompleted { return 0 }
        guard isActive, total > processed else { return nil }

        let elapsed = now.timeIntervalSince(startedAt)
        let sampleDuration = now.timeIntervalSince(lastSampleAt)
        let sampleItems = processed - lastProcessed
        if sampleItems > 0, sampleDuration > 0 {
            let instantaneousRate = Double(sampleItems) / sampleDuration
            if let previous = smoothedItemsPerSecond {
                smoothedItemsPerSecond = previous * 0.72 + instantaneousRate * 0.28
            } else if elapsed >= 0.8, processed >= 2 {
                smoothedItemsPerSecond = Double(processed) / elapsed
            }
            lastSampleAt = now
            lastProcessed = processed
        }

        guard elapsed >= 0.8, processed >= 2,
              let rate = smoothedItemsPerSecond, rate > 0 else { return nil }
        return max(0, Double(total - processed) / rate)
    }
}
