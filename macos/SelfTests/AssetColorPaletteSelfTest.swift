import Foundation

@main
enum AssetColorPaletteSelfTest {
    static func main() {
        let red = repeatedPixel(red: 255, green: 0, blue: 0, count: 24)
        let green = repeatedPixel(red: 0, green: 255, blue: 0, count: 16)
        let blue = repeatedPixel(red: 0, green: 0, blue: 255, count: 8)
        let transparent = repeatedPixel(red: 0, green: 0, blue: 0, alpha: 0, count: 32)
        let colors = AssetColorPaletteExtractor.extract(
            rgbaPixels: red + green + blue + transparent,
            maximumColorCount: 7
        )

        precondition(colors.prefix(3).map(\.hex) == ["#FF0000", "#00FF00", "#0000FF"])
        precondition(colors.count == 3)
        precondition(AssetColorPaletteExtractor.extract(rgbaPixels: [], maximumColorCount: 7).isEmpty)
        precondition(AssetColorPaletteExtractor.extract(rgbaPixels: red, maximumColorCount: 0).isEmpty)

        let translucent = repeatedPixel(red: 64, green: 32, blue: 16, alpha: 128, count: 2)
        let unpremultiplied = AssetColorPaletteExtractor.extract(rgbaPixels: translucent, maximumColorCount: 1)
        precondition(unpremultiplied.first?.red == 127)
        precondition(unpremultiplied.first?.green == 63)
        precondition(unpremultiplied.first?.blue == 31)

        print("Asset color palette self-test passed")
    }

    private static func repeatedPixel(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8 = 255,
        count: Int
    ) -> [UInt8] {
        Array(repeating: [red, green, blue, alpha], count: count).flatMap { $0 }
    }
}
