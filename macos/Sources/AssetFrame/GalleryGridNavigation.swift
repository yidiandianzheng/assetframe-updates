enum GalleryGridNavigation {
    static func destinationIndex(
        from currentIndex: Int,
        itemCount: Int,
        columnCount: Int,
        direction: GalleryNavigationDirection
    ) -> Int? {
        guard itemCount > 0, (0..<itemCount).contains(currentIndex) else { return nil }
        let columns = max(1, columnCount)
        let column = currentIndex % columns

        switch direction {
        case .left:
            guard column > 0 else { return nil }
            return currentIndex - 1
        case .right:
            let candidate = currentIndex + 1
            guard column + 1 < columns, candidate < itemCount else { return nil }
            return candidate
        case .up:
            let candidate = currentIndex - columns
            return candidate >= 0 ? candidate : nil
        case .down:
            let candidate = currentIndex + columns
            return candidate < itemCount ? candidate : nil
        }
    }

    static func destinationID(
        from currentID: String,
        orderedIDs: [String],
        columnCount: Int,
        direction: GalleryNavigationDirection
    ) -> String? {
        guard let currentIndex = orderedIDs.firstIndex(of: currentID),
              let destinationIndex = destinationIndex(
                from: currentIndex,
                itemCount: orderedIDs.count,
                columnCount: columnCount,
                direction: direction
              ) else { return nil }
        return orderedIDs[destinationIndex]
    }
}
