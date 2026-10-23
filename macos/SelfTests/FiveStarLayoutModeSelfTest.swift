import Foundation

@main
struct FiveStarLayoutModeSelfTest {
    static func main() {
        precondition(FiveStarLayoutMode.cards.rawValue == "卡片")
        precondition(FiveStarLayoutMode.masonry.rawValue == "瀑布流")
        precondition(FiveStarLayoutMode.allCases == [.cards, .masonry])
        precondition(FiveStarLayoutMode.masonry.systemImage != FiveStarLayoutMode.cards.systemImage)
        print("FiveStarLayoutModeSelfTest passed")
    }
}
