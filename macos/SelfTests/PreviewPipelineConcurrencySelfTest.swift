import AppKit
import CoreGraphics
import ImageIO

@main
struct PreviewPipelineConcurrencySelfTest {
    static func main() async throws {
        var admission = PreviewImagePipeline.DecodeAdmission()
        let first = UUID(), second = UUID(), prefetched = UUID(), background = UUID()
        admission.enqueue(first, priority: .utility)
        admission.enqueue(second, priority: .userInitiated)
        precondition(admission.acquire(second) && admission.acquire(first))
        for id in [prefetched, background] { admission.enqueue(id, priority: .utility) }
        precondition(!admission.acquire(prefetched), "Decode concurrency stays bounded")
        admission.promote(prefetched, to: .visiblePreview)
        admission.release(second)
        precondition(!admission.acquire(background), "Queued prefetch promoted by a visible request must outrank background work")
        precondition(admission.acquire(prefetched))
        admission.release(first)
        precondition(admission.acquire(background), "Background work resumes after the user request is admitted")
        admission.release(prefetched); admission.release(background)
        let cancelledUser = UUID(), remaining = UUID()
        admission.enqueue(cancelledUser, priority: .userInitiated)
        admission.enqueue(remaining, priority: .utility)
        admission.cancel(cancelledUser)
        precondition(admission.acquire(remaining), "Cancelled users must not starve background requests")
        admission.release(remaining)
        precondition(admission.active == 0)
        let neighborA = UUID(), neighborB = UUID(), cardA = UUID(), cardB = UUID(), preview = UUID()
        admission.enqueue(neighborA, priority: .utility)
        admission.enqueue(neighborB, priority: .utility)
        precondition(admission.acquire(neighborA))
        precondition(!admission.acquire(neighborB), "Neighbor work must leave a slot for an opened image")
        admission.enqueue(cardA, priority: .userInitiated)
        admission.enqueue(cardB, priority: .userInitiated)
        admission.enqueue(preview, priority: .visiblePreview)
        precondition(!admission.acquire(cardA) && admission.acquire(preview), "Opened image must outrank queued cards")
        admission.release(preview)
        precondition(!admission.acquire(cardB) && admission.acquire(cardA), "Equal priorities must be FIFO")
        admission.release(cardA)
        admission.cancel(cardB)
        admission.promote(neighborA, to: .visiblePreview)
        precondition(admission.acquire(neighborB), "Visible waiter promotes active speculative work too")
        admission.release(neighborA); admission.release(neighborB)
        precondition(admission.active == 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assetframe-preview-candidate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 4096, height: 2160, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2160))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))

        let request = PreviewImageRequest(path: url.path, sourceIdentity: "candidate-v1", sourceWidth: 4096, sourceHeight: 2160, priority: .visiblePreview)
        let group = DispatchGroup(); let lock = NSLock(); var results = 0
        var decodedImages: Set<ObjectIdentifier> = []
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<96 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let caller = PreviewImageRequest(path: url.path, sourceIdentity: "caller-\(index)", sourceWidth: 4096, sourceHeight: 2160)
                let value = PreviewImagePipeline.shared.load(request: caller, viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
                if let image = value.image {
                    lock.lock(); results += 1; decodedImages.insert(ObjectIdentifier(image)); lock.unlock()
                }
                group.leave()
            }
        }
        precondition(group.wait(timeout: .now() + .seconds(20)) == .success, "same-key waiters must not deadlock")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        precondition(results == 96, "same-key concurrent loads must all complete")
        precondition(decodedImages.count == 1, "不同界面身份应复用同一文件版本的解码结果")

        for index in 0..<12 {
            PreviewImagePipeline.shared.cancelPendingAndClearMemory()
            let prefetch = Task.detached(priority: .utility) {
                PreviewImagePipeline.shared.load(request: PreviewImageRequest(path: url.path,
                    sourceIdentity: "prefetch-\(index)", sourceWidth: 4096, sourceHeight: 2160, priority: .utility),
                    viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
            }
            await Task.yield()
            let visible = Task.detached(priority: .userInitiated) {
                await PreviewImagePipeline.shared.loadAsync(request: request,
                    viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
            }
            await Task.yield()
            prefetch.cancel()
            let visibleResult = await visible.value
            precondition(visibleResult.image != nil, "取消预加载后正式预览不得变为空白")
            _ = await prefetch.value
        }

        let cancelledParent = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PreviewImagePipeline.shared.loadAsync(request: request,
                viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
        }
        let cancelledAsyncResult = await cancelledParent.value
        precondition(cancelledAsyncResult.image == nil, "异步入口不得返回已取消父任务的图片")

        let thumbnailViewport = CGSize(width: 256, height: 256)
        let thumbnail = PreviewImagePipeline.shared.load(request: request, viewportSize: thumbnailViewport, backingScale: 1, fullResolution: false)
        for index in 0..<32 {
            let copy = root.appendingPathComponent("thumbnail-\(index).png")
            try FileManager.default.copyItem(at: url, to: copy)
            let card = PreviewImageRequest(path: copy.path, sourceIdentity: "card-\(index)", sourceWidth: 4096, sourceHeight: 2160)
            precondition(PreviewImagePipeline.shared.load(request: card, viewportSize: thumbnailViewport,
                backingScale: 1, fullResolution: false).image != nil)
        }
        _ = PreviewImagePipeline.shared.load(request: request, viewportSize: thumbnailViewport, backingScale: 1, fullResolution: true)
        let reusedThumbnail = PreviewImagePipeline.shared.load(request: request, viewportSize: thumbnailViewport, backingScale: 1, fullResolution: false)
        precondition(thumbnail.image != nil && thumbnail.image === reusedThumbnail.image,
                     "32 张卡片及原图预览后仍应保留小图缓存")

        let oldVersion = PreviewImagePipeline.shared.load(request: request, viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
        context.setFillColor(NSColor.systemRed.cgColor); context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2160))
        let updatedDestination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(updatedDestination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(updatedDestination))
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: url.path)
        let changedFile = PreviewImageRequest(path: url.path, sourceIdentity: "changed-file", sourceWidth: 4096, sourceHeight: 2160)
        let newVersion = PreviewImagePipeline.shared.load(request: changedFile, viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
        precondition(newVersion.image != nil && oldVersion.image !== newVersion.image,
                     "文件版本改变后不能继续复用旧图")

        let sourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let thumbnailDirectory = SSDPreviewCache.directory("Thumbnails")
        precondition(SSDPreviewCache.prepare(thumbnailDirectory))
        let diskThumbnail = thumbnailDirectory.appendingPathComponent(SSDPreviewCache.thumbnailKey(
            path: url.path, size: Int64(sourceValues.fileSize ?? 0), modified: sourceValues.contentModificationDate, pixels: 512) + ".png")
        let tinyDestination = CGImageDestinationCreateWithURL(diskThumbnail as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(tinyDestination, context.makeImage()!.cropping(to: CGRect(x: 0, y: 0, width: 128, height: 128))!, nil)
        precondition(CGImageDestinationFinalize(tinyDestination))
        let offline = PreviewImageRequest(path: url.path, sourceIdentity: "offline", sourceWidth: 4096, sourceHeight: 2160, allowSourceRead: false)
        let offlinePreview = PreviewImagePipeline.shared.load(request: offline, viewportSize: CGSize(width: 512, height: 512), backingScale: 1, fullResolution: false)
        precondition(offlinePreview.image != nil && offlinePreview.pixelSize?.width == 128,
                     "禁止读取原文件时仍应显示已有低分辨率缓存")
        let upgraded = PreviewImagePipeline.shared.load(request: changedFile, viewportSize: CGSize(width: 512, height: 512), backingScale: 1, fullResolution: false)
        precondition(upgraded.pixelSize?.width == 512, "原文件可读时应升级过小的画册缓存")

        PreviewImagePipeline.shared.cancelPendingAndClearMemory()
        let cancelled = Task.detached {
            PreviewImagePipeline.shared.load(request: PreviewImageRequest(path: url.path, sourceIdentity: "cancel-generation", sourceWidth: 4096, sourceHeight: 2160), viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: true)
        }
        cancelled.cancel()
        PreviewImagePipeline.shared.cancelPendingAndClearMemory()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult.image == nil, "cancelled generation must not publish")
        let changed = PreviewImageRequest(path: url.path, sourceIdentity: "candidate-v2", sourceWidth: 4096, sourceHeight: 2160)
        let result = PreviewImagePipeline.shared.load(request: changed, viewportSize: CGSize(width: 800, height: 600), backingScale: 2, fullResolution: false)
        precondition(result.image != nil, "source identity after refresh must decode")
        let drained = PreviewImagePipeline.shared.workSnapshot()
        precondition(drained.values.allSatisfy { $0 == 0 }, "All decode tasks must drain after cancellation and completion")
        print("Preview work drained: \(drained)")
        print(String(format: "Preview pipeline candidate self-test passed: priority_promotion=pass mixed_identity_coalescing=96/96 decoded_images=1 elapsed=%.1fms cancelled_prefetch_waiters=12/12 async_cancellation=pass thumbnail_retention=pass file_version_invalidation=pass offline_cache=pass undersized_cache_upgrade=pass refresh_identity=pass bounded_target=%@ cancellation_generation=pass", elapsed, result.pixelSize!.width <= 3200 ? "pass" : "fail"))
    }
}
