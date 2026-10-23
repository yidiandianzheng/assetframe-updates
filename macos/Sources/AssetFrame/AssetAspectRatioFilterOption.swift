import Foundation

enum AssetAspectRatioFilterOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case landscape = "横图"
    case portrait = "竖图"
    case square = "方形"
    case panoramic = "细长横图"
    case fourThree = "4:3"
    case threeFour = "3:4"
    case sixteenNine = "16:9"
    case nineSixteen = "9:16"
    case custom = "自定比例"

    var id: Self { self }

    func matches(ratio: Double, customRatio: Double?) -> Bool {
        guard ratio.isFinite, ratio > 0 else { return false }
        return switch self {
        case .landscape: ratio > 1.05
        case .portrait: ratio < 0.95
        case .square: (0.95...1.05).contains(ratio)
        case .panoramic: ratio >= 2.0
        case .fourThree: Self.near(ratio, target: 4.0 / 3.0)
        case .threeFour: Self.near(ratio, target: 3.0 / 4.0)
        case .sixteenNine: Self.near(ratio, target: 16.0 / 9.0)
        case .nineSixteen: Self.near(ratio, target: 9.0 / 16.0)
        case .custom:
            customRatio.map { Self.near(ratio, target: $0) } ?? false
        }
    }

    static func ratio(for asset: AssetItem) -> Double? {
        guard let width = asset.pixelWidth, let height = asset.pixelHeight, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    private static func near(_ value: Double, target: Double) -> Bool {
        abs(value - target) / target <= 0.035
    }
}
