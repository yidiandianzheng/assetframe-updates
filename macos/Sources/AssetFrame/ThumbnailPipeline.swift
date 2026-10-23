import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

final class ThumbnailPipeline: @unchecked Sendable {
    static let shared = ThumbnailPipeline()
    typealias Completion = @MainActor @Sendable (NSImage?) -> Void
    private enum RequestPriority: Equatable { case visible, prefetch }
    private struct ImageTransfer: @unchecked Sendable { let value: NSImage? }

    /// NSCache 不能缓存 nil；用轻量标记避免损坏、离线或已删除的图片在每次滚动复用时重复解码。
    private final class FailedThumbnail: NSObject {}

    private let memoryCache = NSCache<NSString, NSImage>()
    private let failedCache = NSCache<NSString, FailedThumbnail>()
    private let operationQueue: OperationQueue
    private let lock = NSLock()
    private var requestKeys: [UUID: String] = [:]
    private var subscribers: [String: [UUID: Completion]] = [:]
    private var operations: [String: Operation] = [:]
    private let diskCacheURL: URL

    private init() {
        operationQueue = OperationQueue()
        operationQueue.name = "向量时刻资产缩略图"
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 4
        memoryCache.countLimit = 480
        memoryCache.totalCostLimit = 192 * 1024 * 1024
        failedCache.countLimit = 1_000
        diskCacheURL = SSDPreviewCache.directory("Thumbnails")
    }

    @discardableResult
    @MainActor
    func request(asset: AssetItem, size: CGSize, completion: @escaping Completion) -> UUID? {
        request(asset: asset, size: size, priority: .visible, completion: completion)
    }

    @discardableResult
    @MainActor
    private func request(asset: AssetItem, size: CGSize, priority: RequestPriority, completion: @escaping Completion) -> UUID? {
        let pixelSize = max(size.width, size.height) * 2 <= 512 ? 512 : 1024
        let key = cacheKey(asset: asset, pixelSize: pixelSize)
        if let cached = memoryCache.object(forKey: key as NSString) {
            completion(cached)
            return nil
        }
        if failedCache.object(forKey: key as NSString) != nil {
            completion(nil)
            return nil
        }

        let requestID = UUID()
        let sourcePath = asset.imagePath
        let cachedURL = diskCacheURL.appendingPathComponent("\(key).png")
        let operation = BlockOperation { [weak self] in
            guard let self, self.isActive(key) else { return }
            let image: NSImage? = autoreleasepool {
                // NSImage(contentsOf:) can defer JPEG decoding until AppKit draws
                // the card. Downsampling through ImageIO here guarantees decoding
                // stays on this background operation.
                if let cached = self.downsample(path: cachedURL.path, pixelSize: pixelSize) {
                    return cached
                }
                guard !sourcePath.isEmpty,
                      let generated = self.downsample(path: sourcePath, pixelSize: pixelSize) else { return nil }
                self.persist(generated, to: cachedURL)
                return generated
            }
            guard self.isActive(key) else { return }
            if let image {
                let cost = max(1, Int(image.size.width * image.size.height * 4))
                self.memoryCache.setObject(image, forKey: key as NSString, cost: cost)
            } else {
                self.failedCache.setObject(FailedThumbnail(), forKey: key as NSString)
            }
            let transferredImage = ImageTransfer(value: image)
            Task { @MainActor [weak self] in
                self?.finish(key: key, image: transferredImage.value)
            }
        }
        lock.lock()
        requestKeys[requestID] = key
        if subscribers[key] != nil {
            subscribers[key]?[requestID] = completion
            // 可见卡片追上预读任务时，立即提升队列优先级，避免快速滚动后“眼前的图”排在预读图之后。
            if priority == .visible, let operation = operations[key], !operation.isExecuting {
                operation.queuePriority = .veryHigh
                operation.qualityOfService = .userInitiated
            }
            lock.unlock()
            return requestID
        }
        subscribers[key] = [requestID: completion]
        operations[key] = operation
        operation.queuePriority = priority == .visible ? .veryHigh : .low
        operation.qualityOfService = priority == .visible ? .userInitiated : .utility
        lock.unlock()
        operationQueue.addOperation(operation)
        return requestID
    }

    @MainActor
    func cancel(_ requestID: UUID?) {
        guard let requestID else { return }
        lock.lock()
        guard let key = requestKeys.removeValue(forKey: requestID) else { lock.unlock(); return }
        subscribers[key]?.removeValue(forKey: requestID)
        var operation: Operation?
        if subscribers[key]?.isEmpty != false {
            subscribers.removeValue(forKey: key)
            operation = operations.removeValue(forKey: key)
        }
        lock.unlock()
        operation?.cancel()
    }

    @discardableResult
    @MainActor
    func prefetch(assets: [AssetItem], size: CGSize) -> [String: UUID] {
        let pixelSize = max(size.width, size.height) * 2 <= 512 ? 512 : 1024
        var requestIDs: [String: UUID] = [:]
        for asset in assets {
            let key = cacheKey(asset: asset, pixelSize: pixelSize)
            if memoryCache.object(forKey: key as NSString) != nil { continue }
            lock.lock()
            let alreadyLoading = operations[key] != nil
            lock.unlock()
            if !alreadyLoading,
               let requestID = request(asset: asset, size: size, priority: .prefetch, completion: { _ in }) {
                requestIDs[asset.id] = requestID
            }
        }
        return requestIDs
    }

    private func isActive(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return subscribers[key]?.isEmpty == false
    }

    @MainActor
    private func finish(key: String, image: NSImage?) {
        lock.lock()
        let callbacks = subscribers.removeValue(forKey: key)?.map { $0 }
        if let callbacks { for (requestID, _) in callbacks { requestKeys.removeValue(forKey: requestID) } }
        operations.removeValue(forKey: key)
        lock.unlock()
        callbacks?.forEach { _, completion in completion(image) }
    }

    private func cacheKey(asset: AssetItem, pixelSize: Int) -> String {
        return SSDPreviewCache.thumbnailKey(path: asset.imagePath, size: asset.sourceFileSize ?? 0, modified: asset.sourceModifiedAt, pixels: pixelSize)
    }

    private func downsample(path: String, pixelSize: Int) -> NSImage? {
        let fileURL = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let commonOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        let extensionName = fileURL.pathExtension.lowercased()
        let canUseEmbeddedThumbnail = ["heic", "heif"].contains(extensionName)
        if canUseEmbeddedThumbnail {
            var embeddedOptions = commonOptions
            embeddedOptions[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary),
               max(embedded.width, embedded.height) >= Int(Double(pixelSize) * 0.70) {
                return NSImage(cgImage: embedded, size: NSSize(width: embedded.width, height: embedded.height))
            }
        }
        var generatedOptions = commonOptions
        generatedOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, generatedOptions as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }

    private func persist(_ image: NSImage, to url: URL) {
        guard SSDPreviewCache.prepare(url.deletingLastPathComponent()),
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let jpeg = bitmap.representation(using: .png, properties: [:]) else { return }
        try? jpeg.write(to: url, options: .atomic)
    }
}
