import AppKit

@MainActor
@main
struct GalleryCardChromeSelfTest {
    static func main() {
        precondition(
            GalleryCardChrome.backgroundColor(isSelected: false).alphaComponent == 0,
            "未选中图片卡必须透明，避免圆角露出浅色假白边"
        )
        precondition(GalleryCardChrome.borderWidth(isSelected: false) == 0)
        precondition(GalleryCardChrome.borderColor(isSelected: false).alphaComponent == 0)
        precondition(GalleryCardChrome.borderWidth(isSelected: true) == 2, "选中态仍须保留蓝色边框")
        precondition(GalleryCardChrome.backgroundColor(isSelected: true).alphaComponent > 0)
        print("GalleryCardChromeSelfTest passed")
    }
}
