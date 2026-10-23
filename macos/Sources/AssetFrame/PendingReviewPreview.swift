import SwiftUI

struct PendingReviewPreview: View {
    let item: PendingImportItem
    let onOpenOriginal: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let previewSize = CGSize(
                width: max(360, min(1_160, proxy.size.width - 36)),
                height: max(320, min(760, proxy.size.height - 36))
            )
            ZStack {
                GraphiteTheme.previewCanvas
                AssetThumbnail(
                    asset: item.previewAsset,
                    size: previewSize,
                    contentMode: .fit,
                    backgroundColor: GraphiteTheme.previewCanvas
                )
                .id(item.id)
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
                .accessibilityLabel("当前筛选图片，\(item.originalFilename)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button("查看 100% 原图", systemImage: "arrow.up.left.and.arrow.down.right", action: onOpenOriginal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(16)
            }
            .overlay(alignment: .bottomLeading) {
                Label("屏幕级预览 · 入库保持原图字节", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(16)
            }
        }
    }
}
