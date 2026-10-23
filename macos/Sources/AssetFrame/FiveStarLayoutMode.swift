import Foundation

enum FiveStarLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case cards = "卡片"
    case masonry = "瀑布流"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .cards: "rectangle.grid.2x2"
        case .masonry: "square.grid.3x3.topleft.filled"
        }
    }
}
