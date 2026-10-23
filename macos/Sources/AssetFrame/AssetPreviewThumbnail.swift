import SwiftUI

struct AssetPreviewThumbnail: View {
    let asset: AssetItem
    var size: CGSize = CGSize(width: 54, height: 54)
    var contentMode: ContentMode = .fill
    var isEnabled = true
    var showsOverlays = true

    @ViewBuilder
    var body: some View {
        if isEnabled {
            Button {
                NotificationCenter.default.post(
                    name: .previewAssetImage,
                    object: nil,
                    userInfo: ["id": asset.id]
                )
            } label: {
                AssetThumbnail(
                    asset: asset,
                    size: size,
                    contentMode: contentMode,
                    showsOverlays: showsOverlays
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览“\(asset.name)”高清原图")
            .accessibilityHint("在独立窗口中打开")
            .help("点击预览高清原图")
        } else {
            AssetThumbnail(
                asset: asset,
                size: size,
                contentMode: contentMode,
                showsOverlays: showsOverlays
            )
        }
    }
}
