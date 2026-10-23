import Foundation

enum AssetGalleryLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case adaptive = "自适应"
    case grid = "整齐网格"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .adaptive: "rectangle.grid.1x2"
        case .grid: "square.grid.3x3"
        }
    }
}
