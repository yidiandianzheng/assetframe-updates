import AppKit

struct FeedbackScreenshot {
    let data: Data
    let preview: NSImage
}

@MainActor
enum FeedbackScreenshotCapture {
    static func capture(window: NSWindow?, region: NormalizedRect, padding: CGFloat = 28) -> FeedbackScreenshot? {
        guard let contentView = window?.contentView else { return nil }
        let bounds = contentView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let topLeftRect = region.rect(in: bounds.size)
        let appKitRect = contentView.isFlipped ? topLeftRect : CGRect(
                x: topLeftRect.minX,
                y: bounds.height - topLeftRect.maxY,
                width: topLeftRect.width,
                height: topLeftRect.height
            )
        let captureRect = appKitRect.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard captureRect.width > 1, captureRect.height > 1,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: captureRect) else { return nil }

        contentView.cacheDisplay(in: captureRect, to: bitmap)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
              data.count <= FeedbackSubmissionV1.maximumScreenshotBytes,
              let preview = NSImage(data: data) else { return nil }
        return FeedbackScreenshot(data: data, preview: preview)
    }
}
