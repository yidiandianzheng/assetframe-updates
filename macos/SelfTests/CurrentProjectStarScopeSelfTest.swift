import Foundation

@main
struct CurrentProjectStarScopeSelfTest {
    static func main() {
        let rated = CurrentProjectStarScope.rated
        precondition(!rated.includes(starRating: 0))
        for rating in 1...5 {
            precondition(rated.includes(starRating: rating))
        }

        let threeStars = CurrentProjectStarScope.rating(3)
        precondition(threeStars.includes(starRating: 3))
        precondition(!threeStars.includes(starRating: 2))
        precondition(threeStars.rating == 3)
        precondition(rated.rating == nil)
        print("CurrentProjectStarScopeSelfTest passed")
    }
}
