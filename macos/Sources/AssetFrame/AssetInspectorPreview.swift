import SwiftUI

/// Eagle 式右侧素材预览台：完整构图、文件格式和主色板随当前选择同步更新。
struct AssetInspectorPreview: View {
    let asset: AssetItem
    var opensPreview = true

    @State private var dominantColors: [AssetDominantColor] = []
    @State private var isLoadingPalette = false

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let fittedSize = fittedImageSize(in: proxy.size)
                ZStack {
                    GraphiteTheme.card.opacity(0.45)
                    AssetPreviewThumbnail(
                        asset: asset,
                        size: fittedSize,
                        contentMode: .fit,
                        isEnabled: opensPreview,
                        showsOverlays: false
                    )
                    .overlay(alignment: .topLeading) {
                        if !formatLabel.isEmpty {
                            Text(formatLabel)
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                                .accessibilityLabel("文件格式 \(formatLabel)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .aspectRatio(1.28, contentMode: .fit)

            InspectorColorPalette(colors: dominantColors, isLoading: isLoadingPalette)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(GraphiteTheme.card.opacity(0.52), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .task(id: paletteIdentity) {
            await loadPalette()
        }
    }

    private var formatLabel: String {
        AssetFileFormat.normalizedExtension(for: asset).uppercased()
    }

    private var paletteIdentity: String {
        [
            asset.imagePath,
            String(asset.sourceFileSize ?? 0),
            asset.sourceModifiedAt?.timeIntervalSince1970.description ?? "0"
        ].joined(separator: "|")
    }

    private func fittedImageSize(in container: CGSize) -> CGSize {
        let available = CGSize(
            width: max(1, container.width - 20),
            height: max(1, container.height - 16)
        )
        guard let width = asset.pixelWidth,
              let height = asset.pixelHeight,
              width > 0,
              height > 0 else { return available }

        let imageAspect = CGFloat(width) / CGFloat(height)
        let availableAspect = available.width / available.height
        if imageAspect > availableAspect {
            return CGSize(width: available.width, height: available.width / imageAspect)
        }
        return CGSize(width: available.height * imageAspect, height: available.height)
    }

    @MainActor
    private func loadPalette() async {
        dominantColors = []
        guard !asset.imagePath.isEmpty else {
            isLoadingPalette = false
            return
        }
        if let cached = AssetColorPaletteCache.shared.colors(forKey: paletteIdentity) {
            dominantColors = cached
            isLoadingPalette = false
            return
        }

        isLoadingPalette = true
        let path = asset.imagePath
        let colors = await Task.detached(priority: .utility) {
            AssetColorPaletteExtractor.extract(filePath: path)
        }.value
        guard !Task.isCancelled else { return }
        AssetColorPaletteCache.shared.setColors(colors, forKey: paletteIdentity)
        dominantColors = colors
        isLoadingPalette = false
    }
}
