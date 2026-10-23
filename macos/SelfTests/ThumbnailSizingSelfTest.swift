import CoreGraphics
import Foundation

@main
struct ThumbnailSizingSelfTest {
    static func main() {
        precondition(
            ThumbnailPixelTier.resolvedPixelSize(for: CGSize(width: 54, height: 54)) == 256
        )
        precondition(
            ThumbnailPixelTier.resolvedPixelSize(for: CGSize(width: 108, height: 74)) == 256
        )
        precondition(
            ThumbnailPixelTier.resolvedPixelSize(for: CGSize(width: 216, height: 144)) == 512
        )
        precondition(
            ThumbnailPixelTier.resolvedPixelSize(for: CGSize(width: 320, height: 220)) == 2_048
        )
        precondition(
            ThumbnailPixelTier.resolvedPixelSize(for: CGSize(width: 1_160, height: 760)) == 2_048
        )
        precondition(ThumbnailPixelTier.lowerPixelSizes(than: 2_048) == [512, 256])
        precondition(ThumbnailPixelTier.lowerPixelSizes(than: 256).isEmpty)

        print("Thumbnail sizing self-test passed")
    }
}
