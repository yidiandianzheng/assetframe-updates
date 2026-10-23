import SwiftUI

struct EaglePreviewToolbar: View {
    let selectedIndex: Int?
    let assetCount: Int
    let filename: String?
    @Binding var magnification: CGFloat
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    let canSelectPrevious: Bool
    let canSelectNext: Bool
    let onClose: () -> Void
    let onFitToWindow: () -> Void
    let onActualSize: () -> Void
    let onCopyOriginal: () -> Void
    let onRevealInFinder: () -> Void
    let showsExportAction: Bool
    let onAddToExportLibrary: () -> Void
    let onSelectPrevious: () -> Void
    let onSelectNext: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            iconButton("返回画册", systemImage: "chevron.backward", help: "返回画册（Esc）", action: onClose)

            if let selectedIndex {
                Text("\(selectedIndex + 1) / \(assetCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Text(filename ?? "")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)

            Spacer(minLength: 10)

            zoomControls

            Divider().frame(height: 18)

            iconButton("适合窗口", systemImage: "arrow.down.right.and.arrow.up.left", help: "适合窗口（⌘0）", action: onFitToWindow)
                .keyboardShortcut("0", modifiers: [.command])
            Button("1:1", action: onActualSize)
                .font(.caption.monospacedDigit().weight(.semibold))
                .buttonStyle(.borderless)
                .help("按原始像素查看（⌘1）")
                .keyboardShortcut("1", modifiers: [.command])

            Divider().frame(height: 18)

            iconButton("复制原图", systemImage: "photo.on.rectangle", help: "复制原图，可直接粘贴到 Codex", action: onCopyOriginal)
            iconButton("在 Finder 中显示", systemImage: "folder", help: "在 Finder 中显示原文件", action: onRevealInFinder)
            if showsExportAction {
                iconButton("加入导出库", systemImage: "shippingbox.badge.plus", help: "加入导出库", action: onAddToExportLibrary)
            }

            Divider().frame(height: 18)

            iconButton(
                showsSidebar ? "隐藏目录" : "显示目录",
                systemImage: "sidebar.left",
                help: showsSidebar ? "隐藏左侧目录" : "显示左侧目录",
                action: { showsSidebar.toggle() }
            )
            .foregroundStyle(showsSidebar ? GraphiteTheme.accent : .secondary)

            iconButton(
                showsInspector ? "隐藏详情" : "显示详情",
                systemImage: "sidebar.right",
                help: showsInspector ? "隐藏右侧详情" : "显示右侧详情",
                action: { showsInspector.toggle() }
            )
            .foregroundStyle(showsInspector ? GraphiteTheme.accent : .secondary)

            Divider().frame(height: 18)

            iconButton("上一张", systemImage: "chevron.left", help: "上一张（←）", action: onSelectPrevious)
                .disabled(!canSelectPrevious)
            iconButton("下一张", systemImage: "chevron.right", help: "下一张（→）", action: onSelectNext)
                .disabled(!canSelectNext)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(GraphiteTheme.toolbar)
    }

    private var zoomControls: some View {
        HStack(spacing: 7) {
            Image(systemName: "minus")
                .foregroundStyle(.tertiary)
            Slider(value: $magnification, in: 0.05...8, step: 0.05)
                .frame(width: 128)
                .accessibilityLabel("图片缩放")
            Image(systemName: "plus")
                .foregroundStyle(.tertiary)
            Text("\(Int((magnification * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .help("缩放图片；双击图片可在适合窗口和 1:1 之间切换")
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .help(help)
            .accessibilityLabel(title)
    }
}
