import AppKit
import Foundation
import ImageIO

@main struct SSDPreviewCacheSelfTest {
    static func main() throws {
        let root = SSDPreviewCache.root
        precondition(root.path.contains("assetframe-qa."), "Run only with isolated QA root")
        let source = root.deletingLastPathComponent().appendingPathComponent("original.png")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: source)
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        SSDPreviewCache.warmThumbnail(path: source.path, size: Int64(values.fileSize!), modified: values.contentModificationDate)
        let key = SSDPreviewCache.thumbnailKey(path: source.path, size: Int64(values.fileSize!), modified: values.contentModificationDate, pixels: 512)
        let thumbnail = SSDPreviewCache.directory("Thumbnails").appendingPathComponent(key + ".png")
        precondition(FileManager.default.fileExists(atPath: thumbnail.path))
        let cg = CGImageSourceCreateWithURL(thumbnail as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(cg, 0, nil)! as NSDictionary
        precondition((props[kCGImagePropertyPixelWidth] as? Int) == 512)
        let request = PreviewImageRequest(path: source.path, sourceIdentity: "test", sourceWidth: 2048, sourceHeight: 1024)
        let small = PreviewImagePipeline.shared.load(request: request, viewportSize: CGSize(width: 400, height: 300), backingScale: 1, fullResolution: false)
        precondition(small.image != nil && small.pixelSize!.width < 2048)
        let full = PreviewImagePipeline.shared.load(request: request, viewportSize: CGSize(width: 400, height: 300), backingScale: 1, fullResolution: true)
        precondition(full.pixelSize?.width == 2048)
        let unchanged = try Data(contentsOf: source)
        precondition(unchanged == data)
        // Retain persisted file identity when an external volume disappears.
        var offline = PreviewImageRequest(path: source.path, sourceIdentity: "offline", sourceWidth: 2048, sourceHeight: 1024,
            sourceFileSize: Int64(values.fileSize!), sourceModifiedAt: values.contentModificationDate, allowSourceRead: false)
        PreviewImagePipeline.shared.cancelPendingAndClearMemory()
        let away = source.appendingPathExtension("away")
        try FileManager.default.moveItem(at: source, to: away)
        let cachedOffline = PreviewImagePipeline.shared.load(request: offline, viewportSize: CGSize(width: 512, height: 512), backingScale: 1, fullResolution: false)
        precondition(cachedOffline.image != nil, "Offline source identity must find an existing disk thumbnail")
        try FileManager.default.moveItem(at: away, to: source)
        offline.allowSourceRead = true
        let reconnected = PreviewImagePipeline.shared.load(request: offline, viewportSize: CGSize(width: 512, height: 512), backingScale: 1, fullResolution: false)
        precondition(reconnected.image != nil)
        precondition(!SSDPreviewCache.prepare(source.deletingLastPathComponent().appendingPathComponent("not-cache")))
        let svg = root.deletingLastPathComponent().appendingPathComponent("fallback.svg")
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180">
          <rect width="320" height="180" fill="#336699"/>
        </svg>
        """.utf8).write(to: svg)
        precondition(MaterialThumbnailFallback.load(path: svg.path) != nil, "AppKit fallback must render a valid SVG")
        print("SSDPreviewCacheSelfTest passed: isolated cache, 512px thumbnail, screen preview, original resolution, SVG fallback, unchanged source, path confinement")
    }
}
