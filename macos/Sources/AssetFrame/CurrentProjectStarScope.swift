import Foundation

enum CurrentProjectStarScope: Equatable, Sendable {
    case rated
    case rating(Int)

    func includes(starRating: Int) -> Bool {
        switch self {
        case .rated:
            (1...5).contains(starRating)
        case .rating(let value):
            starRating == value
        }
    }

    var rating: Int? {
        guard case .rating(let value) = self else { return nil }
        return value
    }
}
