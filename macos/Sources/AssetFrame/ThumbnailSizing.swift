import CoreGraphics

enum ThumbnailPixelTier: Int, CaseIterable, Sendable {
    case compact = 256
    case card = 512
    case screen = 2_048

    static func resolvedPixelSize(for pointSize: CGSize, scale: Double = 2) -> Int {
        let longestSide = max(Double(pointSize.width), Double(pointSize.height))
        let requiredPixels = max(1, Int(ceil(longestSide * max(1, scale))))
        return allCases.first(where: { requiredPixels <= $0.rawValue })?.rawValue ?? screen.rawValue
    }

    static func lowerPixelSizes(than pixelSize: Int) -> [Int] {
        allCases
            .map(\.rawValue)
            .filter { $0 < pixelSize }
            .sorted(by: >)
    }
}
