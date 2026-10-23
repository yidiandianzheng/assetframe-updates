import Foundation

enum AssetDecisionFilter: Equatable, Sendable {
    case only(UserDecision)
    case excluding(UserDecision)

    var displayName: String {
        switch self {
        case let .only(decision): "只看\(decision.displayName)"
        case let .excluding(decision): "不看\(decision.displayName)"
        }
    }

    var systemImage: String {
        switch self {
        case .only: "eye.fill"
        case .excluding: "eye.slash.fill"
        }
    }

    var cacheKey: String {
        switch self {
        case let .only(decision): "only:\(decision.rawValue)"
        case let .excluding(decision): "excluding:\(decision.rawValue)"
        }
    }

    func includes(_ decision: UserDecision) -> Bool {
        switch self {
        case let .only(required): decision == required
        case let .excluding(excluded): decision != excluded
        }
    }

    /// The decision represented by this filter when it has a single positive
    /// value. Kept separate from `excluding` so callers do not accidentally
    /// present an exclusion as a selected status.
    var selectedDecision: UserDecision? {
        guard case let .only(decision) = self else { return nil }
        return decision
    }
}
