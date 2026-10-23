import Foundation

@main
struct GalleryGridNavigationSelfTest {
    @MainActor
    static func main() {
        let sixColumns = (0..<16).map { "A\($0)" }

        expect(7, from: 8, count: 16, columns: 6, direction: .left)
        expect(9, from: 8, count: 16, columns: 6, direction: .right)
        expect(2, from: 8, count: 16, columns: 6, direction: .up)
        expect(14, from: 8, count: 16, columns: 6, direction: .down)

        expectNil(from: 6, count: 16, columns: 6, direction: .left, "每行第一张不能向左跨行")
        expectNil(from: 5, count: 16, columns: 6, direction: .right, "每行最后一张不能向右跨行")
        expectNil(from: 2, count: 16, columns: 6, direction: .up, "第一行不能继续向上")
        expectNil(from: 11, count: 16, columns: 6, direction: .down, "残缺末行没有同列图片时必须停住")

        expect(1, from: 0, count: 3, columns: 1, direction: .down)
        expectNil(from: 0, count: 3, columns: 1, direction: .left, "单列视图不能左右移动")
        expectNil(from: 2, count: 3, columns: 1, direction: .down, "最后一张不能循环到开头")

        precondition(
            GalleryGridNavigation.destinationID(
                from: "A8",
                orderedIDs: sixColumns,
                columnCount: 6,
                direction: .down
            ) == "A14",
            "导航结果必须使用当前画廊顺序"
        )

        let reordered = ["A8", "A2", "A14", "A1"]
        precondition(
            GalleryGridNavigation.destinationID(
                from: "A2",
                orderedIDs: reordered,
                columnCount: 2,
                direction: .down
            ) == "A1",
            "筛选或排序变化后必须使用新顺序"
        )
        precondition(
            GalleryGridNavigation.destinationID(
                from: "A8",
                orderedIDs: ["A2", "A14", "A1"],
                columnCount: 2,
                direction: .right
            ) == nil,
            "当前图片退出结果后不得导航到无关资产"
        )

        let owner = Owner()
        let navigator = GalleryPreviewNavigator()
        var scrolledIDs: [String] = []
        var invalidationCount = 0
        navigator.setInvalidationHandler { invalidationCount += 1 }
        navigator.attach(
            owner: owner,
            orderedAssetIDs: sixColumns,
            columnCount: 6,
            scrollToAsset: { scrolledIDs.append($0) }
        )
        precondition(navigator.begin(at: "A8"))
        precondition(navigator.focusedAssetID == "A8" && scrolledIDs == ["A8"])
        precondition(navigator.move(.down) == "A14")
        precondition(navigator.focusedAssetID == "A14" && scrolledIDs == ["A8", "A14"])
        navigator.synchronize(orderedAssetIDs: ["A1", "A2"], columnCount: 2)
        precondition(navigator.focusedAssetID == nil && invalidationCount == 1)
        navigator.detach(owner: owner)
        precondition(invalidationCount == 1, "已清空焦点时拆除画廊不得重复关闭预览")

        print("GalleryGridNavigationSelfTest passed")
    }

    private final class Owner {}

    private static func expect(
        _ expected: Int,
        from current: Int,
        count: Int,
        columns: Int,
        direction: GalleryNavigationDirection
    ) {
        precondition(
            GalleryGridNavigation.destinationIndex(
                from: current,
                itemCount: count,
                columnCount: columns,
                direction: direction
            ) == expected
        )
    }

    private static func expectNil(
        from current: Int,
        count: Int,
        columns: Int,
        direction: GalleryNavigationDirection,
        _ message: String
    ) {
        precondition(
            GalleryGridNavigation.destinationIndex(
                from: current,
                itemCount: count,
                columnCount: columns,
                direction: direction
            ) == nil,
            message
        )
    }
}
