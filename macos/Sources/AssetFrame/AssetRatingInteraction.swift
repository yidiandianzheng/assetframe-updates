import Foundation

enum AssetRatingInteraction {
    static func rating(current: Int, selecting value: Int) -> Int {
        min(5, max(1, value))
    }

    static func clearedRating() -> Int { 0 }
}
