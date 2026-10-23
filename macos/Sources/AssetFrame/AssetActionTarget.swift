import Foundation

enum AssetActionTarget: Hashable, Sendable {
    case formal(String)
    case pending(String)
    case quickReview(String)
    case globalFiveStar(String)
    case material(String)

    var id: String {
        switch self {
        case .formal(let id), .pending(let id), .quickReview(let id),
             .globalFiveStar(let id), .material(let id):
            id
        }
    }

    var galleryID: String {
        switch self {
        case .pending(let id), .quickReview(let id): "PENDING-\(id)"
        default: id
        }
    }

    var capabilities: AssetActionCapabilities {
        switch self {
        case .formal:
            AssetActionCapabilities(
                canRate: true, ratingPromotesToFormal: false,
                canClassify: true, canTag: true, canAddToCommon: true,
                canReveal: true, canRename: true, removalRoute: .appTrash
            )
        case .pending:
            AssetActionCapabilities(
                canRate: true, ratingPromotesToFormal: true,
                canClassify: true, canTag: true, canAddToCommon: false,
                canReveal: true, canRename: true, removalRoute: .discardPending
            )
        case .quickReview:
            AssetActionCapabilities(
                canRate: false, ratingPromotesToFormal: false,
                canClassify: true, canTag: true, canAddToCommon: false,
                canReveal: true, canRename: false, removalRoute: .systemTrashAfterIdentityCheck
            )
        case .globalFiveStar:
            AssetActionCapabilities(
                canRate: false, ratingPromotesToFormal: false,
                canClassify: false, canTag: false, canAddToCommon: false,
                canReveal: true, canRename: false, removalRoute: nil
            )
        case .material:
            AssetActionCapabilities(
                canRate: false, ratingPromotesToFormal: false,
                canClassify: true, canTag: true, canAddToCommon: false,
                canReveal: true, canRename: false, removalRoute: nil
            )
        }
    }

    static func gallery(_ galleryID: String) -> AssetActionTarget {
        let prefix = "PENDING-"
        guard galleryID.hasPrefix(prefix) else { return .formal(galleryID) }
        return .pending(String(galleryID.dropFirst(prefix.count)))
    }
}

struct AssetActionCapabilities: Equatable, Sendable {
    let canRate: Bool
    let ratingPromotesToFormal: Bool
    let canClassify: Bool
    let canTag: Bool
    let canAddToCommon: Bool
    let canReveal: Bool
    let canRename: Bool
    let removalRoute: AssetRemovalRoute?
}
