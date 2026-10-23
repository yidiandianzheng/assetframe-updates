import CoreGraphics
import Foundation
import ImageIO

struct AssetDominantColor: Equatable, Identifiable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var id: UInt32 {
        UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

enum AssetColorPaletteExtractor {
    private struct Bucket {
        var count = 0
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0

        mutating func add(red: Int, green: Int, blue: Int) {
            count += 1
            redTotal += red
            greenTotal += green
            blueTotal += blue
        }

        var color: AssetDominantColor {
            AssetDominantColor(
                red: UInt8(redTotal / max(1, count)),
                green: UInt8(greenTotal / max(1, count)),
                blue: UInt8(blueTotal / max(1, count))
            )
        }
    }

    static func extract(filePath: String, maximumColorCount: Int = 7) -> [AssetDominantColor] {
        guard maximumColorCount > 0, !filePath.isEmpty else { return [] }
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return [] }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return [] }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return extract(
            rgbaPixels: pixels,
            maximumColorCount: maximumColorCount
        )
    }

    static func extract(
        rgbaPixels: [UInt8],
        maximumColorCount: Int = 7
    ) -> [AssetDominantColor] {
        guard maximumColorCount > 0, rgbaPixels.count >= 4 else { return [] }

        var buckets: [UInt16: Bucket] = [:]
        buckets.reserveCapacity(512)

        for offset in stride(from: 0, to: rgbaPixels.count - 3, by: 4) {
            let alpha = Int(rgbaPixels[offset + 3])
            guard alpha >= 32 else { continue }

            let red = unpremultiplied(Int(rgbaPixels[offset]), alpha: alpha)
            let green = unpremultiplied(Int(rgbaPixels[offset + 1]), alpha: alpha)
            let blue = unpremultiplied(Int(rgbaPixels[offset + 2]), alpha: alpha)
            let key = UInt16(red >> 4) << 8 | UInt16(green >> 4) << 4 | UInt16(blue >> 4)
            buckets[key, default: Bucket()].add(red: red, green: green, blue: blue)
        }

        let candidates = buckets.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.color.id < rhs.color.id
            }
            .prefix(96)
            .map(\.color)

        var result: [AssetDominantColor] = []
        appendDistinct(from: candidates, minimumDistance: 34, maximumColorCount: maximumColorCount, to: &result)
        if result.count < maximumColorCount {
            appendDistinct(from: candidates, minimumDistance: 18, maximumColorCount: maximumColorCount, to: &result)
        }
        return result
    }

    private static func appendDistinct(
        from candidates: [AssetDominantColor],
        minimumDistance: Double,
        maximumColorCount: Int,
        to result: inout [AssetDominantColor]
    ) {
        for candidate in candidates where result.count < maximumColorCount {
            guard !result.contains(candidate) else { continue }
            guard result.allSatisfy({ colorDistance($0, candidate) >= minimumDistance }) else { continue }
            result.append(candidate)
        }
    }

    private static func unpremultiplied(_ value: Int, alpha: Int) -> Int {
        guard alpha < 255 else { return value }
        return min(255, value * 255 / max(1, alpha))
    }

    private static func colorDistance(_ lhs: AssetDominantColor, _ rhs: AssetDominantColor) -> Double {
        let red = Double(Int(lhs.red) - Int(rhs.red))
        let green = Double(Int(lhs.green) - Int(rhs.green))
        let blue = Double(Int(lhs.blue) - Int(rhs.blue))
        return (red * red + green * green + blue * blue).squareRoot()
    }
}

final class AssetColorPaletteCache: @unchecked Sendable {
    static let shared = AssetColorPaletteCache()

    private final class Entry: NSObject {
        let colors: [AssetDominantColor]

        init(colors: [AssetDominantColor]) {
            self.colors = colors
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 256
    }

    func colors(forKey key: String) -> [AssetDominantColor]? {
        cache.object(forKey: key as NSString)?.colors
    }

    func setColors(_ colors: [AssetDominantColor], forKey key: String) {
        cache.setObject(Entry(colors: colors), forKey: key as NSString)
    }
}
