import AppKit
import CoreImage
import ImageIO
import QuartzCore

enum LargeImagePolicy {
    static func needsTiles(width: Int?, height: Int?) -> Bool {
        guard let width, let height, width > 0, height > 0 else { return false }
        return Double(width) * Double(height) > 40_000_000 || max(width, height) > 16_000
    }
}

/// File-backed CoreImage region rendering; never creates an entire original CGImage.
/// Codec internals may still decode a full source. Output tiles and concurrency are bounded.
final class OriginalTileRenderer: NSObject, CALayerDelegate, @unchecked Sendable {
    let size: CGSize
    private let image: CIImage
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private let gate = NSLock()
    private let stateLock = NSLock()
    private let cache = NSCache<NSString, Tile>()
    private var stopped = false
    private class Tile: NSObject { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    init?(url: URL) {
        guard let original = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              original.extent.width.isFinite, original.extent.height.isFinite,
              original.extent.width > 0, original.extent.height > 0 else { return nil }
        image = original.transformed(by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY))
        size = image.extent.size
        super.init()
        cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 48
    }
    func stop() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        cache.removeAllObjects()
        DispatchQueue.global(qos: .utility).async { self.gate.lock(); self.context.clearCaches(); self.gate.unlock() }
    }
    func tile(rect: CGRect, scale: CGFloat) -> CGImage? {
        let region = rect.intersection(CGRect(origin: .zero, size: size))
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        // Keep each returned tile <=1024px, even when magnification reaches 8x.
        let level = min(max(0.025, scale), min(1024 / region.width, 1024 / region.height))
        let key = "\(region)|\(level)" as NSString
        gate.lock(); defer { gate.unlock() }
        stateLock.lock(); let cancelled = stopped; stateLock.unlock()
        guard !cancelled else { return nil }
        if let cached = cache.object(forKey: key) { return cached.image }
        let cropped = image.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY)).transformed(by: CGAffineTransform(scaleX: level, y: level))
        guard let output = context.createCGImage(cropped, from: CGRect(x: 0, y: 0, width: ceil(region.width * level), height: ceil(region.height * level))) else { return nil }
        cache.setObject(Tile(output), forKey: key, cost: output.bytesPerRow * output.height)
        return output
    }
    func draw(_ layer: CALayer, in ctx: CGContext) {
        let region = ctx.boundingBoxOfClipPath.intersection(CGRect(origin: .zero, size: size))
        let transform = ctx.ctm
        let scale = hypot(transform.a, transform.c)
        guard let output = tile(rect: region, scale: scale) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(output, in: region)
    }
}

@MainActor
final class OriginalTileOverlay: NSView {
    private let tileLayer = CATiledLayer()
    private let renderer: OriginalTileRenderer
    init(renderer: OriginalTileRenderer) {
        self.renderer = renderer
        super.init(frame: CGRect(origin: .zero, size: renderer.size))
        wantsLayer = true
        tileLayer.tileSize = CGSize(width: 512, height: 512)
        tileLayer.levelsOfDetail = 7; tileLayer.levelsOfDetailBias = 4
        tileLayer.delegate = renderer; tileLayer.frame = bounds
        layer?.addSublayer(tileLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func stop() { tileLayer.delegate = nil; tileLayer.removeFromSuperlayer(); renderer.stop() }
}
