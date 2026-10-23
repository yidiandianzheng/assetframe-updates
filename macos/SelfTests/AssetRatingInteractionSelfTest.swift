import Foundation

@main
struct AssetRatingInteractionSelfTest {
    static func main() {
        precondition(AssetRatingInteraction.rating(current: 0, selecting: 3) == 3)
        precondition(AssetRatingInteraction.rating(current: 5, selecting: 5) == 5, "重复点击当前星级不得清零")
        precondition(AssetRatingInteraction.rating(current: 4, selecting: 8) == 5)
        precondition(AssetRatingInteraction.clearedRating() == 0, "清除评分必须走独立动作")
        print("AssetRatingInteractionSelfTest passed")
    }
}
