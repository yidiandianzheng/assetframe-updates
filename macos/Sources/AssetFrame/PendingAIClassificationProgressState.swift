import Foundation

struct PendingAIClassificationProgressState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case analyzing
        case completed
        case failed
    }

    let id: UUID
    var phase: Phase
    var processed: Int
    var total: Int
    var succeeded: Int
    var failed: Int
    var message: String

    var fraction: Double {
        total > 0 ? min(1, Double(processed) / Double(total)) : 0
    }
}
