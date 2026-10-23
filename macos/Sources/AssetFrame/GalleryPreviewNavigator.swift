import Observation

@MainActor
@Observable
final class GalleryPreviewNavigator {
    private(set) var focusedAssetID: String?

    @ObservationIgnored private var ownerID: ObjectIdentifier?
    @ObservationIgnored private var orderedAssetIDs: [String] = []
    @ObservationIgnored private var columnCount = 1
    @ObservationIgnored private var scrollToAsset: ((String) -> Void)?
    @ObservationIgnored private var invalidationHandler: (() -> Void)?

    func attach(
        owner: AnyObject,
        orderedAssetIDs: [String],
        columnCount: Int,
        scrollToAsset: @escaping (String) -> Void
    ) {
        ownerID = ObjectIdentifier(owner)
        self.scrollToAsset = scrollToAsset
        synchronize(orderedAssetIDs: orderedAssetIDs, columnCount: columnCount)
    }

    func detach(owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner) else { return }
        ownerID = nil
        orderedAssetIDs = []
        columnCount = 1
        scrollToAsset = nil
        invalidateFocusedAsset()
    }

    func synchronize(orderedAssetIDs: [String], columnCount: Int) {
        self.orderedAssetIDs = orderedAssetIDs
        self.columnCount = max(1, columnCount)
        if let focusedAssetID, !orderedAssetIDs.contains(focusedAssetID) {
            invalidateFocusedAsset()
        }
    }

    @discardableResult
    func begin(at assetID: String) -> Bool {
        guard orderedAssetIDs.contains(assetID) else { return false }
        focusedAssetID = assetID
        scrollToAsset?(assetID)
        return true
    }

    func move(_ direction: GalleryNavigationDirection) -> String? {
        guard let focusedAssetID,
              let destinationID = GalleryGridNavigation.destinationID(
                from: focusedAssetID,
                orderedIDs: orderedAssetIDs,
                columnCount: columnCount,
                direction: direction
              ) else { return nil }
        self.focusedAssetID = destinationID
        scrollToAsset?(destinationID)
        return destinationID
    }

    func clear() {
        focusedAssetID = nil
    }

    func setInvalidationHandler(_ handler: (() -> Void)?) {
        invalidationHandler = handler
    }

    private func invalidateFocusedAsset() {
        guard focusedAssetID != nil else { return }
        focusedAssetID = nil
        invalidationHandler?()
    }
}
