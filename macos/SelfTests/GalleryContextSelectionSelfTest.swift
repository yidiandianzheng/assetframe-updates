import Foundation

@main
struct GalleryContextSelectionSelfTest {
    static func main() {
        let selected: Set<String> = ["A", "B", "C"]

        precondition(
            GalleryContextSelection.actionIDs(clickedID: "B", selectedIDs: selected) == selected,
            "右键已选中图片时，回收操作必须覆盖全部选中项"
        )
        precondition(
            GalleryContextSelection.actionIDs(clickedID: "D", selectedIDs: selected) == ["D"],
            "右键未选中图片时，操作范围必须收缩为当前图片"
        )
        precondition(
            GalleryContextSelection.actionIDs(clickedID: "A", selectedIDs: []) == Set(["A"])
        )

        print("GalleryContextSelectionSelfTest passed")
    }
}
