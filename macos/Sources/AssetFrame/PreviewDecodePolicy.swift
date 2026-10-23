import CoreGraphics

enum PreviewDecodePolicy {
    static let minimumPixelSize = 96
    static let maximumPreviewPixelSize = 3_200

    static func targetPixelSize(
        sourceWidth: Int?, sourceHeight: Int?, viewportSize: CGSize,
        backingScale: CGFloat, fullResolution: Bool
    ) -> Int {
        let sourceMaximum = max(sourceWidth ?? 0, sourceHeight ?? 0)
        if fullResolution, sourceMaximum > 0 { return sourceMaximum }
        let viewportMaximum = Int(ceil(max(viewportSize.width, viewportSize.height) * max(1, backingScale)))
        let requested = min(maximumPreviewPixelSize, max(minimumPixelSize, viewportMaximum))
        return sourceMaximum > 0 ? min(requested, sourceMaximum) : requested
    }
}
