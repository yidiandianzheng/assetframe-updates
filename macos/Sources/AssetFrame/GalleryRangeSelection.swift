import Foundation

enum GalleryRangeSelection {
    static func ids(
        orderedIDs: [String], anchor: String?, clicked: String,
        selected: Set<String>, additive: Bool
    ) -> Set<String> {
        guard let clickedIndex = orderedIDs.firstIndex(of: clicked) else { return selected }
        let selectedIndices = Set(orderedIDs.indices.filter { selected.contains(orderedIDs[$0]) })
        return Set(indices(
            anchor: anchor.flatMap { orderedIDs.firstIndex(of: $0) },
            clicked: clickedIndex, selected: selectedIndices,
            itemCount: orderedIDs.count, additive: additive
        ).map { orderedIDs[$0] })
    }

    static func indices(
        anchor: Int?,
        clicked: Int,
        selected: Set<Int>,
        itemCount: Int,
        additive: Bool
    ) -> Set<Int> {
        guard itemCount > 0, clicked >= 0, clicked < itemCount else { return selected }
        let validAnchor = anchor.flatMap { (0..<itemCount).contains($0) ? $0 : nil }
        let start = validAnchor ?? selected.filter { (0..<itemCount).contains($0) }.min() ?? clicked
        let interval = Set(min(start, clicked)...max(start, clicked))
        return additive ? selected.union(interval) : interval
    }
}
