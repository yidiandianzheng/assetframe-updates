import AppKit
import CoreGraphics
import ImageIO
import CryptoKit

struct PreviewImageRequest: Hashable, Sendable {
    let path: String
    let sourceIdentity: String
    let sourceWidth: Int?
    let sourceHeight: Int?
    var sourceFileSize: Int64? = nil
    var sourceModifiedAt: Date? = nil
    var allowSourceRead = true
    var priority: PreviewImagePriority = .userInitiated
}

enum PreviewImagePriority: Int, Sendable {
    case utility = 0, userInitiated = 1, visiblePreview = 2
}

struct PreviewImageResult: @unchecked Sendable {
    let image: NSImage?
    let pixelSize: CGSize?
}

final class PreviewImagePipeline: @unchecked Sendable {
    static let shared = PreviewImagePipeline()

    private final class CachedImage: NSObject {
        let result: PreviewImageResult
        init(_ result: PreviewImageResult) { self.result = result }
    }

    private let diskWriteGate = DispatchSemaphore(value: 1)
    private let diskWriter = DispatchQueue(label: "AssetFrame.preview-cache-writer", qos: .utility)
    private let cache = NSCache<NSString, CachedImage>()
    private let thumbnailCache = NSCache<NSString, CachedImage>()
    private final class Metadata: NSObject {
        let values: URLResourceValues
        let expiresAt: UInt64
        init(values: URLResourceValues, expiresAt: UInt64) { self.values = values; self.expiresAt = expiresAt }
    }
    private let metadataCache = NSCache<NSString, Metadata>()
    private final class InFlight {
        let condition = NSCondition()
        var result: PreviewImageResult?
        var completed = false
        var wasAbandoned = false
        let id = UUID()
    }
    private let inFlightLock = NSLock()
    private var inFlight: [String: InFlight] = [:]
    private let priorityCondition = NSCondition()
    private var admission = DecodeAdmission()

    /// Accessed only while priorityCondition is locked. Queued promotions must
    /// participate in admission, just like requests originally made by a user.
    struct DecodeAdmission {
        var active: Int { running.count }
        var queued: Int { pending.count }
        private var running: [UUID: PreviewImagePriority] = [:]
        private var pending: [UUID: PreviewImagePriority] = [:]
        private var order: [UUID] = []

        mutating func enqueue(_ id: UUID, priority: PreviewImagePriority) {
            if pending[id] == nil { order.append(id) }
            pending[id] = priority
        }
        mutating func promote(_ id: UUID, to priority: PreviewImagePriority = .userInitiated) {
            if let current = pending[id], priority.rawValue > current.rawValue { pending[id] = priority }
            if let current = running[id], priority.rawValue > current.rawValue { running[id] = priority }
        }
        mutating func cancel(_ id: UUID) {
            pending.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
        mutating func acquire(_ id: UUID) -> Bool {
            guard active < 2, let priority = pending[id],
                  !pending.values.contains(where: { $0.rawValue > priority.rawValue }),
                  order.first(where: { pending[$0] == priority }) == id else { return false }
            // Speculative neighbors use only one slot, leaving capacity for a
            // newly opened image. Existing codec calls cannot be preempted.
            if priority == .utility && running.values.contains(.utility) { return false }
            pending.removeValue(forKey: id)
            order.removeAll { $0 == id }
            running[id] = priority
            return true
        }
        mutating func release(_ id: UUID) { running.removeValue(forKey: id) }
    }
    private let generationLock = NSLock()
    private var generation: UInt64 = 0

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 192 * 1024 * 1024
        thumbnailCache.countLimit = 480
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
        metadataCache.countLimit = 128
    }

    /// Abandons queued results without touching the rebuildable disk cache.
    /// In-flight codec work cannot always be interrupted, but it is prevented
    /// from publishing stale images after a gallery refresh.
    func cancelPendingAndClearMemory() {
        generationLock.lock()
        generation &+= 1
        generationLock.unlock()
        cache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        metadataCache.removeAllObjects()
    }

    func workSnapshot() -> [String: Int] {
        priorityCondition.lock()
        let active = admission.active, queued = admission.queued
        priorityCondition.unlock()
        inFlightLock.lock()
        let flights = inFlight.count
        inFlightLock.unlock()
        return ["activeDecodes": active, "queuedDecodes": queued, "inFlightRequests": flights]
    }

    private func currentGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == value
    }

    func load(request: PreviewImageRequest, viewportSize: CGSize, backingScale: CGFloat, fullResolution: Bool) -> PreviewImageResult {
        load(request: request, viewportSize: viewportSize, backingScale: backingScale,
             fullResolution: fullResolution, retryAbandonedFlight: true)
    }

    /// SwiftUI task cancellation must reach the detached codec worker too.
    func loadAsync(request: PreviewImageRequest, viewportSize: CGSize, backingScale: CGFloat, fullResolution: Bool) async -> PreviewImageResult {
        guard !Task.isCancelled else { return PreviewImageResult(image: nil, pixelSize: nil) }
        let worker = Task.detached(priority: request.priority == .utility ? .utility : .userInitiated) {
            self.load(request: request, viewportSize: viewportSize, backingScale: backingScale, fullResolution: fullResolution)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        return Task.isCancelled ? PreviewImageResult(image: nil, pixelSize: nil) : result
    }

    private func load(request: PreviewImageRequest, viewportSize: CGSize, backingScale: CGFloat,
                      fullResolution: Bool, retryAbandonedFlight: Bool) -> PreviewImageResult {
        guard !Task.isCancelled else { return PreviewImageResult(image: nil, pixelSize: nil) }
        let requestGeneration = currentGeneration()
        let target = PreviewDecodePolicy.targetPixelSize(
            sourceWidth: request.sourceWidth, sourceHeight: request.sourceHeight,
            viewportSize: viewportSize, backingScale: backingScale, fullResolution: fullResolution
        )
        let cacheRoot = SSDPreviewCache.root
        let sourceValues = metadata(for: request, generation: requestGeneration)
        let memoryCache = target <= 512 && !fullResolution ? thumbnailCache : cache
        let sourceSize = sourceValues?.fileSize.map(Int64.init) ?? request.sourceFileSize ?? 0
        let sourceDate = sourceValues?.contentModificationDate ?? request.sourceModifiedAt
        let modified = sourceDate?.timeIntervalSince1970 ?? 0
        // Disk identity stays stable across launches/refreshes and read policies.
        let diskIdentity = "\(cacheRoot.path)|\(request.path)|\(sourceSize)|\(modified)|\(target)|\(fullResolution ? "full" : "preview")"
        // The file version, not the caller's UI identity, owns decoded pixels.
        // Keep the caller version as a fallback when file metadata is unavailable.
        let versionFallback = sourceValues == nil ? "|source:\(request.sourceIdentity)" : ""
        let key = "\(diskIdentity)|g:\(requestGeneration)\(versionFallback)|read:\(request.allowSourceRead)"
        if let cached = memoryCache.object(forKey: key as NSString), isCurrent(requestGeneration), !Task.isCancelled { return cached.result }

        inFlightLock.lock()
        if let existing = inFlight[key] {
            if request.priority != .utility {
                priorityCondition.lock()
                admission.promote(existing.id, to: request.priority)
                priorityCondition.broadcast()
                priorityCondition.unlock()
            }
            inFlightLock.unlock()
            existing.condition.lock()
            while !existing.completed {
                _ = existing.condition.wait(until: Date().addingTimeInterval(0.05))
                if Task.isCancelled || !isCurrent(requestGeneration) { existing.condition.unlock(); return PreviewImageResult(image: nil, pixelSize: nil) }
            }
            let value = existing.result
            let wasAbandoned = existing.wasAbandoned
            existing.condition.unlock()
            guard !Task.isCancelled, isCurrent(requestGeneration) else { return PreviewImageResult(image: nil, pixelSize: nil) }
            if wasAbandoned && retryAbandonedFlight {
                // A cancelled prefetch must not make its still-visible waiter blank.
                inFlightLock.lock()
                if inFlight[key] === existing { inFlight.removeValue(forKey: key) }
                inFlightLock.unlock()
                return load(request: request, viewportSize: viewportSize, backingScale: backingScale,
                            fullResolution: fullResolution, retryAbandonedFlight: false)
            }
            return value ?? PreviewImageResult(image: nil, pixelSize: nil)
        }
        let flight = InFlight()
        priorityCondition.lock()
        admission.enqueue(flight.id, priority: request.priority)
        priorityCondition.unlock()
        inFlight[key] = flight
        inFlightLock.unlock()
        defer {
            priorityCondition.lock()
            admission.cancel(flight.id)
            priorityCondition.broadcast()
            priorityCondition.unlock()
            inFlightLock.lock()
            if inFlight[key] === flight { inFlight.removeValue(forKey: key) }
            inFlightLock.unlock()
            flight.condition.lock()
            let completed = flight.completed
            flight.condition.unlock()
            if !completed { finish(flight, result: PreviewImageResult(image: nil, pixelSize: nil), wasAbandoned: true) }
        }

        // A cache writer can finish between the first lookup and ownership.
        if let cached = memoryCache.object(forKey: key as NSString), isCurrent(requestGeneration), !Task.isCancelled {
            finish(flight, result: cached.result)
            return cached.result
        }
        guard acquireDecodeSlot(flight: flight, generation: requestGeneration) else {
            return PreviewImageResult(image: nil, pixelSize: nil)
        }
        defer { releaseDecodeSlot(flight) }
        guard !Task.isCancelled, isCurrent(requestGeneration) else { return PreviewImageResult(image: nil, pixelSize: nil) }
        let diskKey = SHA256.hash(data: Data(diskIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let thumbnailKey = SSDPreviewCache.thumbnailKey(path: request.path, size: sourceSize, modified: sourceDate, pixels: 512)
        let thumbnailURL = cacheRoot.appendingPathComponent("Thumbnails", isDirectory: true).appendingPathComponent(thumbnailKey + ".png")
        let screenDirectory = cacheRoot.appendingPathComponent("ScreenPreviews", isDirectory: true)
        let screenURL = screenDirectory.appendingPathComponent(diskKey + ".png")
        let diskURL = target <= 512 ? thumbnailURL : screenURL
        let directory = diskURL.deletingLastPathComponent()
        let diskRequest = PreviewImageRequest(path: diskURL.path, sourceIdentity: key, sourceWidth: nil, sourceHeight: nil)
        let firstPaintRequest = PreviewImageRequest(path: thumbnailURL.path, sourceIdentity: key, sourceWidth: nil, sourceHeight: nil)
        let diskSource = target <= 512 && FileManager.default.fileExists(atPath: thumbnailURL.path) ? firstPaintRequest : diskRequest
        let cachedDisk = fullResolution ? PreviewImageResult(image: nil, pixelSize: nil) : decode(request: diskSource, targetPixelSize: target)
        let sourceMaximum = max(request.sourceWidth ?? 0, request.sourceHeight ?? 0)
        let expectedPixels = sourceMaximum > 0 ? min(target, sourceMaximum) : target
        let cachedPixels = max(cachedDisk.pixelSize?.width ?? 0, cachedDisk.pixelSize?.height ?? 0)
        // Older first-paint writers could put a 256px image in the 512px slot.
        // Upgrade undersized cache entries when the source is readable; offline
        // requests keep their smaller usable preview rather than becoming blank.
        let acceptsDisk = cachedDisk.image != nil && (!request.allowSourceRead || cachedPixels >= CGFloat(expectedPixels) * 0.70)
        if acceptsDisk { SSDPreviewCache.recordAccess(diskSource.path == thumbnailURL.path ? thumbnailURL : diskURL) }
        let result = acceptsDisk ? cachedDisk : request.allowSourceRead ? decode(request: request, targetPixelSize: target, fullResolution: fullResolution) : PreviewImageResult(image: nil, pixelSize: nil)
        guard !Task.isCancelled, isCurrent(requestGeneration) else { return PreviewImageResult(image: nil, pixelSize: nil) }
        // First paint does not wait for TIFF/PNG encoding or a disk write. At
        // most one write retains an image; extra cache writes are simply skipped.
        if !fullResolution, target >= 512, !acceptsDisk, result.image != nil,
           diskWriteGate.wait(timeout: .now()) == .success {
            diskWriter.async { [self] in
                defer { diskWriteGate.signal() }
                guard isCurrent(requestGeneration), SSDPreviewCache.prepare(directory),
                      let image = result.image, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .png, properties: [:]),
                      isCurrent(requestGeneration) else { return }
                _ = SSDPreviewCache.write(data, to: diskURL)
            }
        }
        if let image = result.image {
            let cost = max(1, Int(image.size.width * image.size.height * 4))
            generationLock.lock()
            if generation == requestGeneration { memoryCache.setObject(CachedImage(result), forKey: key as NSString, cost: cost) }
            generationLock.unlock()
        }
        guard !Task.isCancelled, isCurrent(requestGeneration) else { return PreviewImageResult(image: nil, pixelSize: nil) }
        finish(flight, result: result)
        return result
    }

    private func metadata(for request: PreviewImageRequest, generation: UInt64) -> URLResourceValues? {
        let cacheKey = "g:\(generation)|\(request.path)|\(request.sourceIdentity)" as NSString
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = metadataCache.object(forKey: cacheKey), cached.expiresAt > now { return cached.values }
        let values = try? URL(fileURLWithPath: request.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let values { metadataCache.setObject(Metadata(values: values, expiresAt: now + 250_000_000), forKey: cacheKey) }
        return values
    }

    private func acquireDecodeSlot(flight: InFlight, generation: UInt64) -> Bool {
        priorityCondition.lock()
        defer { priorityCondition.unlock() }
        while !Task.isCancelled, isCurrent(generation) {
            if admission.acquire(flight.id) { return true }
            _ = priorityCondition.wait(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func finish(_ flight: InFlight, result: PreviewImageResult, wasAbandoned: Bool = false) {
        flight.condition.lock()
        flight.result = result; flight.wasAbandoned = wasAbandoned; flight.completed = true
        flight.condition.broadcast(); flight.condition.unlock()
    }

    private func releaseDecodeSlot(_ flight: InFlight) {
        priorityCondition.lock()
        admission.release(flight.id)
        priorityCondition.broadcast()
        priorityCondition.unlock()
    }

    private func decode(request: PreviewImageRequest, targetPixelSize: Int, fullResolution: Bool = false) -> PreviewImageResult {
        let url = URL(fileURLWithPath: request.path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions) else {
            return PreviewImageResult(image: nil, pixelSize: nil)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? request.sourceWidth ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? request.sourceHeight ?? 0
        let excessive = Double(width) * Double(height) > 40_000_000 || max(width, height) > 16_000
        let requestedTarget = fullResolution && !excessive ? max(width, height, 1) : min(targetPixelSize, PreviewDecodePolicy.maximumPreviewPixelSize)
        let decodeTarget = min(max(PreviewDecodePolicy.minimumPixelSize, requestedTarget), max(width, height, 1))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeTarget,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // HEIC/JPEG files from cameras often carry a ready-made embedded preview.
        // Use it for the first paint and avoid a full codec pass on the main interaction path.
        if decodeTarget < max(width, height, 1) {
            var embeddedOptions = options
            embeddedOptions[kCGImageSourceCreateThumbnailFromImageAlways] = false
            embeddedOptions[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
            if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary),
               max(embedded.width, embedded.height) >= Int(Double(decodeTarget) * 0.70) {
                let size = CGSize(width: embedded.width, height: embedded.height)
                return PreviewImageResult(image: NSImage(cgImage: embedded, size: size), pixelSize: size)
            }
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return PreviewImageResult(image: nil, pixelSize: nil)
        }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return PreviewImageResult(image: NSImage(cgImage: cgImage, size: size), pixelSize: size)
    }
}
