import SwiftUI

struct GalleryHeaderBar: View {
    let title: String
    let assetCount: Int
    let selectedCount: Int
    @Binding var layoutMode: AssetGalleryLayoutMode
    @Binding var sort: AssetSortConfiguration
    @Binding var thumbnailWidth: Double
    @Binding var showsName: Bool
    @Binding var showsDescription: Bool
    @Binding var showsSecondaryInfo: Bool
    @Binding var secondaryInfoMode: AssetSecondaryInfoMode
    @Binding var showsExtension: Bool
    @Binding var showsTags: Bool
    @Binding var showsTagCount: Bool
    @Binding var showsRating: Bool
    @Binding var folderScope: LocalFolderScope
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    let folderScopeEnabled: Bool
    var showsFolderButton = true
    let chooseLocalFolder: () -> Void
    @State private var showsDisplaySettings = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text("图片画册 · \(assetCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GalleryThumbnailSizeControl(width: $thumbnailWidth, compact: true)
                .accessibilityHint("也可以在显示设置中调整")

            HStack(spacing: 10) {
                if selectedCount > 0 {
                    Label("已选 \(selectedCount)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(.tint.opacity(0.09), in: Capsule())
                        .accessibilityLabel("已选择 \(selectedCount) 项")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        if showsFolderButton {
                            folderButton(compact: false)
                            Divider().frame(height: 22)
                        }
                        displaySettingsButton
                    }

                    HStack(spacing: 8) {
                        if showsFolderButton {
                            folderButton(compact: true)
                        }
                        displaySettingsButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(GraphiteTheme.toolbar)
    }

    private var displaySettingsButton: some View {
        Button("显示设置", systemImage: "rectangle.3.group") {
            showsDisplaySettings.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("布局、名称、副信息和栏位显示")
        .popover(isPresented: $showsDisplaySettings, arrowEdge: .bottom) {
            AssetDisplaySettingsPopover(
                layoutMode: $layoutMode,
                sort: $sort,
                thumbnailWidth: $thumbnailWidth,
                showsName: $showsName,
                showsDescription: $showsDescription,
                showsSecondaryInfo: $showsSecondaryInfo,
                secondaryInfoMode: $secondaryInfoMode,
                showsExtension: $showsExtension,
                showsTags: $showsTags,
                showsTagCount: $showsTagCount,
                showsRating: $showsRating,
                folderScope: $folderScope,
                showsSidebar: $showsSidebar,
                showsInspector: $showsInspector,
                folderScopeEnabled: folderScopeEnabled
            )
        }
    }

    @ViewBuilder
    private func folderButton(compact: Bool) -> some View {
        if compact {
            Button("链接本地文件夹", systemImage: "folder.badge.plus", action: chooseLocalFolder)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("链接本地文件夹，保留完整目录结构")
        } else {
            Button("链接本地文件夹", systemImage: "folder.badge.plus", action: chooseLocalFolder)
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("链接本地文件夹，保留完整目录结构")
        }
    }
}
