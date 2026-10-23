import CoreGraphics

enum PreviewPanMath {
    static func draggedOrigin(
        startOrigin: CGPoint,
        viewportTranslation: CGSize,
        magnification: CGFloat
    ) -> CGPoint {
        let safeMagnification = max(0.05, magnification)
        return CGPoint(
            x: startOrigin.x - viewportTranslation.width / safeMagnification,
            y: startOrigin.y - viewportTranslation.height / safeMagnification
        )
    }
}
