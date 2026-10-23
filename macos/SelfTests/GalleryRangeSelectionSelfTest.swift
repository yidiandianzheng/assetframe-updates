import Foundation

@main
struct GalleryRangeSelectionSelfTest {
    static func main() {
        precondition(
            GalleryRangeSelection.indices(anchor: 2, clicked: 7, selected: [2], itemCount: 10, additive: false)
                == Set(2...7)
        )
        precondition(
            GalleryRangeSelection.indices(anchor: 7, clicked: 2, selected: [7], itemCount: 10, additive: false)
                == Set(2...7),
            "向前 Shift 点击也必须选择完整区间"
        )
        precondition(
            GalleryRangeSelection.indices(anchor: 4, clicked: 6, selected: [0, 4], itemCount: 10, additive: true)
                == Set([0, 4, 5, 6]),
            "Command+Shift 应在现有选择上追加区间"
        )
        precondition(
            GalleryRangeSelection.indices(anchor: nil, clicked: 5, selected: [3], itemCount: 10, additive: false)
                == Set(3...5),
            "锚点丢失时应从当前首个选择恢复"
        )
        let ordered = ["z", "a", "m", "b", "c"]
        precondition(GalleryRangeSelection.ids(orderedIDs: ordered, anchor: "a", clicked: "b",
            selected: ["a"], additive: false) == ["a", "m", "b"], "Use display order, never ID sort order")
        precondition(GalleryRangeSelection.ids(orderedIDs: ordered, anchor: "b", clicked: "a",
            selected: ["b"], additive: false) == ["a", "m", "b"])
        precondition(GalleryRangeSelection.ids(orderedIDs: ordered, anchor: "m", clicked: "b",
            selected: ["z", "m"], additive: true) == ["z", "m", "b"])
        precondition(GalleryRangeSelection.ids(orderedIDs: ordered, anchor: "removed", clicked: "c",
            selected: ["b"], additive: false) == ["b", "c"])
        precondition(GalleryRangeSelection.ids(orderedIDs: ordered, anchor: "a", clicked: "removed",
            selected: ["a"], additive: false) == ["a"])
        precondition(GalleryRangeSelection.ids(orderedIDs: [], anchor: nil, clicked: "removed",
            selected: [], additive: false).isEmpty)
        print("GalleryRangeSelectionSelfTest passed")
    }
}
