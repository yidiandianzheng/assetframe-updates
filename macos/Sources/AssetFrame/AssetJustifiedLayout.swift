import AppKit

enum AssetJustifiedSizing {
    static let spacing: CGFloat = 8
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 8
    static let minimumRowHeight: CGFloat = 72
    static let minimumAspectRatio: CGFloat = 0.35
    static let maximumAspectRatio: CGFloat = 4.0
    static let maximumRowHeightMultiplier: CGFloat = 1.35

    static func aspectRatio(width: Int?, height: Int?, fallback: CGFloat = 1.0) -> CGFloat {
        let raw: CGFloat
        if let width, let height, width > 0, height > 0 {
            raw = CGFloat(width) / CGFloat(height)
        } else {
            raw = fallback
        }
        return min(max(raw, minimumAspectRatio), maximumAspectRatio)
    }

    static func frames(
        aspectRatios: [CGFloat],
        containerWidth: CGFloat,
        targetRowHeight: CGFloat,
        metadataHeight: CGFloat = 0
    ) -> [CGRect] {
        guard !aspectRatios.isEmpty else { return [] }

        let contentWidth = max(1, containerWidth - horizontalInset * 2)
        let targetHeight = max(minimumRowHeight, targetRowHeight)
        let normalizedAspects = aspectRatios.map { min(max($0, minimumAspectRatio), maximumAspectRatio) }
        let rows = makeRows(
            aspectRatios: normalizedAspects,
            contentWidth: contentWidth,
            targetRowHeight: targetHeight
        )

        var result = Array(repeating: CGRect.zero, count: normalizedAspects.count)
        var y = verticalInset

        for (rowIndex, row) in rows.enumerated() {
            let isLastRow = rowIndex == rows.count - 1
            let gapWidth = spacing * CGFloat(max(0, row.count - 1))
            let aspectSum = row.reduce(CGFloat.zero) { $0 + normalizedAspects[$1] }
            let justifiedHeight = max(1, (contentWidth - gapWidth) / max(0.05, aspectSum))
            let maximumRowHeight = targetHeight * maximumRowHeightMultiplier
            let rowHeight = isLastRow
                ? min(targetHeight, justifiedHeight)
                : min(maximumRowHeight, justifiedHeight)
            let fillsAvailableWidth = abs(rowHeight - justifiedHeight) < 0.5
                && (!isLastRow || justifiedHeight <= targetHeight)
            let rightEdge = horizontalInset + contentWidth
            var x = horizontalInset

            for (itemOffset, itemIndex) in row.enumerated() {
                let isLastItem = itemOffset == row.count - 1
                let proportionalWidth = normalizedAspects[itemIndex] * rowHeight
                let width = fillsAvailableWidth && isLastItem
                    ? max(1, rightEdge - x)
                    : max(1, proportionalWidth.rounded(.toNearestOrAwayFromZero))
                result[itemIndex] = CGRect(x: x, y: y, width: width, height: rowHeight + metadataHeight)
                x += width + spacing
            }

            y += rowHeight + metadataHeight + spacing
        }

        return result
    }

    private static func makeRows(
        aspectRatios: [CGFloat],
        contentWidth: CGFloat,
        targetRowHeight: CGFloat
    ) -> [[Int]] {
        var rows: [[Int]] = []
        var currentRow: [Int] = []

        for index in aspectRatios.indices {
            let candidate = currentRow + [index]
            let candidateNaturalWidth = naturalWidth(
                row: candidate,
                aspectRatios: aspectRatios,
                rowHeight: targetRowHeight
            )

            guard candidateNaturalWidth >= contentWidth, !currentRow.isEmpty else {
                currentRow = candidate
                continue
            }

            let candidateHeight = justifiedHeight(
                row: candidate,
                aspectRatios: aspectRatios,
                contentWidth: contentWidth
            )
            let currentHeight = justifiedHeight(
                row: currentRow,
                aspectRatios: aspectRatios,
                contentWidth: contentWidth
            )

            if abs(candidateHeight - targetRowHeight) <= abs(currentHeight - targetRowHeight) {
                rows.append(candidate)
                currentRow = []
            } else {
                rows.append(currentRow)
                currentRow = [index]
            }
        }

        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }

    private static func naturalWidth(
        row: [Int],
        aspectRatios: [CGFloat],
        rowHeight: CGFloat
    ) -> CGFloat {
        let imageWidth = row.reduce(CGFloat.zero) { $0 + aspectRatios[$1] * rowHeight }
        return imageWidth + spacing * CGFloat(max(0, row.count - 1))
    }

    private static func justifiedHeight(
        row: [Int],
        aspectRatios: [CGFloat],
        contentWidth: CGFloat
    ) -> CGFloat {
        let aspectSum = row.reduce(CGFloat.zero) { $0 + aspectRatios[$1] }
        let gapWidth = spacing * CGFloat(max(0, row.count - 1))
        return max(1, (contentWidth - gapWidth) / max(0.05, aspectSum))
    }
}

final class AssetJustifiedLayout: NSCollectionViewLayout {
    var orderedIDs: [String] = []
    var aspectRatios: [String: CGFloat] = [:]
    var targetRowHeight: CGFloat = 190
    var metadataHeight: CGFloat = 0

    private var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    // Frames are ordered by row; both minY and maxY are monotonic.
    private var orderedAttributes: [NSCollectionViewLayoutAttributes] = []
    private var calculatedContentSize = CGSize.zero
    private var preparedWidth: CGFloat?

    override func prepare() {
        super.prepare()
        attributes.removeAll(keepingCapacity: true)
        orderedAttributes.removeAll(keepingCapacity: true)
        guard let collectionView else { return }

        let width = collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
        preparedWidth = width
        let itemAspects = orderedIDs.map { aspectRatios[$0] ?? 1.5 }
        let frames = AssetJustifiedSizing.frames(
            aspectRatios: itemAspects,
            containerWidth: width,
            targetRowHeight: targetRowHeight,
            metadataHeight: metadataHeight
        )

        for (index, frame) in frames.enumerated() {
            let indexPath = IndexPath(item: index, section: 0)
            let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            itemAttributes.frame = frame
            attributes[indexPath] = itemAttributes
            orderedAttributes.append(itemAttributes)
        }

        let contentHeight = frames.map(\.maxY).max() ?? 0
        calculatedContentSize = CGSize(
            width: width,
            height: max(collectionView.bounds.height, contentHeight + AssetJustifiedSizing.verticalInset)
        )
    }

    override var collectionViewContentSize: NSSize { calculatedContentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard !rect.isEmpty else { return [] }
        // Locate the first intersecting row instead of scanning every asset on
        // each scroll event. Keep the final intersects check for horizontal clips.
        var low = 0
        var high = orderedAttributes.count
        while low < high {
            let mid = low + (high - low) / 2
            if orderedAttributes[mid].frame.maxY < rect.minY { low = mid + 1 }
            else { high = mid }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        while low < orderedAttributes.count {
            let item = orderedAttributes[low]
            if item.frame.minY > rect.maxY { break }
            if item.frame.intersects(rect) { result.append(item) }
            low += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        // AppKit may already have updated collectionView.bounds by the time it
        // asks this question. Compare against the width used to build frames.
        // Vertical scrolling does not require rebuilding every card.
        guard let preparedWidth else { return true }
        return abs(newBounds.width - preparedWidth) > 0.5
    }
}
