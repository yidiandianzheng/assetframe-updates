import Foundation

enum FiveStarAssetCategory: String, CaseIterable, Identifiable, Sendable {
    case people = "人物"
    case scenes = "场景"
    case props = "道具"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .people: "person.2"
        case .scenes: "photo.on.rectangle.angled"
        case .props: "shippingbox"
        }
    }

    func includes(_ type: AssetType) -> Bool {
        switch self {
        case .people:
            [.person, .creature].contains(type)
        case .scenes:
            [.venue, .scene].contains(type)
        case .props:
            [.prop, .product, .cover, .publishCover, .fixedSymbol, .boundStructure].contains(type)
        }
    }
}
