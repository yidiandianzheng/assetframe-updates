import CoreGraphics

enum PreviewZoomMath {
    static func fitMagnification(
        imageSize: CGSize,
        viewportSize: CGSize,
        contentInset: CGFloat = 6,
        minimumMagnification: CGFloat = 0.05,
        maximumMagnification: CGFloat = 8
    ) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return maximumMagnification }

        let availableWidth = max(0, viewportSize.width - contentInset * 2)
        let availableHeight = max(0, viewportSize.height - contentInset * 2)
        guard availableWidth > 0, availableHeight > 0 else { return maximumMagnification }

        let fitted = min(availableWidth / imageSize.width, availableHeight / imageSize.height)
        return min(maximumMagnification, max(minimumMagnification, fitted))
    }
}
