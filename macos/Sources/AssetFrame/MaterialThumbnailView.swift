import CryptoKit
import AVFoundation
import AppKit
import QuickLook
import QuickLookUI
import QuickLookThumbnailing
import SwiftUI

struct MaterialThumbnailView: View {
    let material: MaterialRecord
    var showFormatBadge = true
    var useFileExtensionBadge = false
    var previewMaximumDimension = 512.0
    var refreshIdentity: UInt64 = 0
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: material.kind.systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
            VStack {
                Spacer()
                HStack {
                    if showFormatBadge { mediaBadge }
                    Spacer()
                    if let duration = material.mediaMetadata?.durationSeconds {
                        Text(Self.durationText(duration))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6)
                            .frame(height: 19)
                            .background(.ultraThickMaterial, in: Capsule())
                    }
                }
                .padding(7)
            }
        }
        .task(id: cacheIdentity) { await reloadThumbnail() }
    }

    private var mediaBadge: some View {
        Text(useFileExtensionBadge ? material.originalFilename.pathExtensionUppercased : badgeText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(.ultraThickMaterial, in: Capsule())
    }

    private var badgeText: String {
        switch material.presentationKind {
        case .animatedImage: "GIF"
        case .video: "视频"
        case .audio: "音频"
        case .stillImage: material.originalFilename.pathExtensionUppercased
        case .document: "文档"
        case .generic: material.kind.rawValue
        }
    }

    private var cacheIdentity: String {
        "\(SSDPreviewCache.root.path)|\(thumbnailPath ?? material.sourceURL ?? material.id)|\(material.sourceModifiedAt?.timeIntervalSince1970 ?? 0)|\(material.fileSize ?? 0)|\(material.production?.coverSeconds ?? -1)|\(Int(previewMaximumDimension))|refresh:\(refreshIdentity)"
    }

    private var thumbnailPath: String? {
        AssetFileLocationResolver.canonicalMaterialPath(for: material)
            ?? material.sourceURL
    }

    private func reloadThumbnail() async {
        image = nil
        for attempt in 0..<2 {
            await loadThumbnail()
            if image != nil || Task.isCancelled { return }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(180)) }
        }
    }

    private func loadThumbnail() async {
        if material.kind == .image, let path = thumbnailPath {
            let material = material
            let previewMaximumDimension = previewMaximumDimension
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return PreviewImageResult(image: nil, pixelSize: nil) }
                let request = PreviewImageRequest(path: path, sourceIdentity: "\(material.id)|\(material.sourceModifiedAt?.timeIntervalSince1970 ?? 0)",
                    sourceWidth: material.mediaMetadata?.pixelWidth, sourceHeight: material.mediaMetadata?.pixelHeight,
                    sourceFileSize: material.fileSize, sourceModifiedAt: material.sourceModifiedAt,
                    allowSourceRead: ImportResumeRecord.availableLocally(URL(fileURLWithPath: path)))
                let viewport = CGSize(width: previewMaximumDimension, height: previewMaximumDimension)
                return PreviewImagePipeline.shared.load(request: request, viewportSize: viewport, backingScale: 1, fullResolution: false)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            image = result.image
            if result.image != nil { return }
            // ImageIO does not decode every format that Quick Look supports.
            // Continue to the existing fallback instead of leaving a permanent icon.
            guard ImportResumeRecord.availableLocally(URL(fileURLWithPath: path)) else { return }
            let appKitFallback = await Task.detached(priority: .utility) {
                PreviewImageResult(image: MaterialThumbnailFallback.load(path: path), pixelSize: nil)
            }.value
            guard !Task.isCancelled else { return }
            if let fallback = appKitFallback.image { image = fallback; return }
        }
        let identity = cacheIdentity
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = SSDPreviewCache.directory("MediaThumbnails")
        let cache = root.appendingPathComponent(key + ".tiff")
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: cache) }.value
        guard !Task.isCancelled else { return }
        if let data, let cached = NSImage(data: data) { SSDPreviewCache.recordAccess(cache); image = cached; return }
        guard let location = material.fileLocation, location.exists else { image = nil; return }
        if material.kind == .video, let seconds = material.production?.coverSeconds {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: location.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: previewMaximumDimension, height: previewMaximumDimension)
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)), !Task.isCancelled {
                image = NSImage(cgImage: frame.image, size: .zero)
                await persistThumbnail(at: cache)
                return
            }
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: location.url,
            size: CGSize(width: previewMaximumDimension, height: previewMaximumDimension),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail]
        )
        let cancellation = ThumbnailRequestCancellation(request)
        do {
            let representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                cancellation.cancel()
            }
            guard !Task.isCancelled else { return }
            image = representation.nsImage
            await persistThumbnail(at: cache)
        } catch {
            guard !Task.isCancelled else { return }
            image = NSWorkspace.shared.icon(forFile: location.path)
        }
    }

    private func persistThumbnail(at url: URL) async {
        guard let data = image?.tiffRepresentation, !Task.isCancelled else { return }
        await Task.detached(priority: .utility) {
            guard SSDPreviewCache.prepare(url.deletingLastPathComponent()) else { return }
            _ = SSDPreviewCache.write(data, to: url)
        }.value
    }

    static func durationText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

@MainActor
final class MaterialQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = MaterialQuickLookController()
    private var previewURL: URL?

    func show(_ material: MaterialRecord) {
        guard let location = material.fileLocation, location.exists else { return }
        previewURL = location.url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

private extension String {
    var pathExtensionUppercased: String {
        let value = (self as NSString).pathExtension.uppercased()
        return value.isEmpty ? "图片" : value
    }
}

// The request is fully configured before sharing; the cancellation handler only
// passes it back to Quick Look's cancellation API, never mutates its properties.
private final class ThumbnailRequestCancellation: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request
    init(_ request: QLThumbnailGenerator.Request) { self.request = request }
    func cancel() { QLThumbnailGenerator.shared.cancel(request) }
}
