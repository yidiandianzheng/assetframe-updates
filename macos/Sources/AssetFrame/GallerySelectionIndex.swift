import Foundation

struct GallerySelectionIndex {
    private let positionsByID: [String: Int]

    init(orderedIDs: [String]) {
        positionsByID = Dictionary(
            uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) }
        )
    }

    func indexes(for selectedIDs: Set<String>) -> IndexSet {
        IndexSet(selectedIDs.compactMap { positionsByID[$0] })
    }
}
