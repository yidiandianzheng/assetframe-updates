import Foundation

struct PendingVisionClassificationProgressState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case classifying
        case completed
    }

    let id: UUID
    var phase: Phase
    var processed: Int
    var total: Int
    var adopted: Int
    var message: String

    var fraction: Double {
        total > 0 ? min(1, Double(processed) / Double(total)) : 0
    }
}
