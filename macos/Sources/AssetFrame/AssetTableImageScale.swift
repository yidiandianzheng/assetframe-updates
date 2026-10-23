import CoreGraphics

enum AssetTableImageScale: String, CaseIterable, Identifiable, Sendable {
    case compact = "紧凑"
    case standard = "标准"
    case large = "大图"

    var id: Self { self }

    var columnWidth: CGFloat {
        switch self {
        case .compact: 72
        case .standard: 116
        case .large: 164
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 58
        case .standard: 88
        case .large: 122
        }
    }

    var thumbnailSize: CGSize {
        switch self {
        case .compact: CGSize(width: 48, height: 48)
        case .standard: CGSize(width: 96, height: 72)
        case .large: CGSize(width: 144, height: 104)
        }
    }
}
