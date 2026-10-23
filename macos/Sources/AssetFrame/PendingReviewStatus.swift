import Foundation

enum PendingReviewStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case kept
    case discarded

    var displayName: String {
        switch self {
        case .unreviewed: "未判断"
        case .kept: "已保留"
        case .discarded: "废片"
        }
    }

    var systemImage: String {
        switch self {
        case .unreviewed: "circle"
        case .kept: "checkmark.circle.fill"
        case .discarded: "xmark.circle.fill"
        }
    }
}
