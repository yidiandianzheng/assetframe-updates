import CoreGraphics
import AppKit

@main
struct AssetJustifiedLayoutSelfTest {
    @MainActor static func main() {
        let collection = NSCollectionView(frame: CGRect(x: 0, y: 0, width: 0, height: 400))
        let layout = AssetJustifiedLayout()
        collection.collectionViewLayout = layout
        layout.orderedIDs = ["portrait", "landscape"]
        layout.aspectRatios = ["portrait": 0.5, "landscape": 2]
        layout.prepare()
        collection.setFrameSize(NSSize(width: 600, height: 400))
        precondition(layout.shouldInvalidateLayout(forBoundsChange: collection.bounds),
                     "Changing bounds before invalidation must still invalidate zero-width frames")
        layout.prepare()
        precondition(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame.width > 20,
                     "Gallery restored after table must not retain one-pixel cards")
        precondition(!layout.shouldInvalidateLayout(forBoundsChange: CGRect(x: 0, y: 200, width: 600, height: 400)),
                     "Vertical scrolling must not rebuild the whole layout")

        let portrait = AssetJustifiedSizing.aspectRatio(width: 1_000, height: 2_000)
        let landscape = AssetJustifiedSizing.aspectRatio(width: 2_000, height: 1_000)
        precondition(portrait == 0.5)
        precondition(landscape == 2.0)
        precondition(AssetJustifiedSizing.aspectRatio(width: nil, height: nil, fallback: 0.74) == 0.74)
        precondition(AssetJustifiedSizing.aspectRatio(width: 100, height: 10_000) == AssetJustifiedSizing.minimumAspectRatio)
        precondition(AssetJustifiedSizing.aspectRatio(width: 10_000, height: 100) == AssetJustifiedSizing.maximumAspectRatio)

        let aspects: [CGFloat] = [2.0, 2.0, 2.0, 2.0]
        let frames = AssetJustifiedSizing.frames(
            aspectRatios: aspects,
            containerWidth: 1_000,
            targetRowHeight: 200
        )
        precondition(frames.count == aspects.count)
        precondition(frames[0].minX == AssetJustifiedSizing.horizontalInset)
        precondition(abs(frames[0].height - frames[1].height) < 0.001)
        precondition(abs(frames[1].height - frames[2].height) < 0.001)
        precondition(abs(frames[2].maxX - (1_000 - AssetJustifiedSizing.horizontalInset)) < 0.001)
        precondition(frames[3].minY > frames[0].minY)
        precondition(frames[3].height == 200)
        precondition(abs(frames[3].width / frames[3].height - aspects[3]) < 0.001)

        let framesWithFooter = AssetJustifiedSizing.frames(
            aspectRatios: aspects,
            containerWidth: 1_000,
            targetRowHeight: 200,
            metadataHeight: 40
        )
        precondition(abs(framesWithFooter[0].height - frames[0].height - 40) < 0.001)
        precondition(framesWithFooter[3].minY >= frames[3].minY + 40, "信息栏必须进入行高，不能与下一行重叠")

        let mixed = AssetJustifiedSizing.frames(
            aspectRatios: [0.5, 1.0, 1.8, 0.75, 2.4, 1.2, 0.6],
            containerWidth: 1_280,
            targetRowHeight: 190
        )
        precondition(mixed.allSatisfy { $0.width > 0 && $0.height > 0 })
        precondition(mixed.allSatisfy {
            $0.minX >= AssetJustifiedSizing.horizontalInset
                && $0.maxX <= 1_280 - AssetJustifiedSizing.horizontalInset + 0.001
        })

        let eagleLarge = AssetJustifiedSizing.frames(
            aspectRatios: [1.78, 0.75, 1.78, 1.78],
            containerWidth: 1_800,
            targetRowHeight: 680,
            metadataHeight: 36
        )
        precondition(eagleLarge[0].minY == eagleLarge[1].minY, "大横图和竖图应在同一行")
        precondition(eagleLarge[2].minY > eagleLarge[0].minY, "大图模式应在该宽度形成两列左右的行")
        precondition(abs(eagleLarge[1].maxX - (1_800 - AssetJustifiedSizing.horizontalInset)) < 0.001)

        let mixedDocuments = AssetJustifiedSizing.frames(
            aspectRatios: [0.74, 0.74, 0.74, 0.5, 1.78, 0.35, 4.0, 1.0],
            containerWidth: 1_920,
            targetRowHeight: 240,
            metadataHeight: 48
        )
        for first in mixedDocuments.indices {
            for second in mixedDocuments.indices where second > first {
                precondition(!mixedDocuments[first].intersects(mixedDocuments[second]), "混合媒体卡片不能重叠")
            }
        }
        precondition(mixedDocuments.allSatisfy { $0.height <= 240 * AssetJustifiedSizing.maximumRowHeightMultiplier + 48 + 0.001 })

        // Compare the viewport index against exhaustive geometry, including gaps,
        // horizontal clipping, empty results, and a large gallery near its end.
        layout.orderedIDs = (0..<20_000).map(String.init)
        layout.aspectRatios = Dictionary(uniqueKeysWithValues: layout.orderedIDs.enumerated().map {
            ($0.element, CGFloat(($0.offset % 8) + 1) / 2)
        })
        collection.setFrameSize(NSSize(width: 1200, height: 800))
        layout.prepare()
        let all = (0..<20_000).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
        let bottom = all.last!.frame.maxY
        let rects = (0..<100).map { i in
            CGRect(x: i.isMultiple(of: 2) ? 0 : 350, y: CGFloat(i) / 99 * bottom - 50,
                   width: i.isMultiple(of: 2) ? 1200 : 150, height: i.isMultiple(of: 3) ? 1 : 800)
        } + [CGRect.zero, CGRect(x: 0, y: bottom + 100, width: 1200, height: 800)]
        for rect in rects {
            let expected = Set(all.filter { $0.frame.intersects(rect) }.compactMap(\.indexPath))
            let actual = Set(layout.layoutAttributesForElements(in: rect).compactMap(\.indexPath))
            precondition(expected == actual, "Viewport lookup must match exhaustive layout for \(rect)")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var count = 0
        for _ in 0..<20 {
            for rect in rects { count += layout.layoutAttributesForElements(in: rect).count }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "20,000-item viewport benchmark: %.3f ms / 2,040 queries, hits %d", elapsed, count))
        // Replacing results with an empty query must clear the old index.
        layout.orderedIDs = []
        layout.prepare()
        precondition(layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 1200, height: 800)).isEmpty)
        print("Asset justified layout self-test passed")
    }
}
