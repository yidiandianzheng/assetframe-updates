import SwiftUI

struct GlobalFiveStarCard: View {
    let record: GlobalFiveStarRecord
    let project: ProjectRecord
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onCopyOriginalImage: () -> Void
    let onCopyPath: () -> Void
    let projectActionTitle: String?
    let onProjectAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggleSelection) {
                AssetThumbnail(
                    asset: record.galleryAsset,
                    size: CGSize(width: 280, height: 178),
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 190)
                .background(GraphiteTheme.assetWell, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .tint)
                            .font(.title2)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择\(record.asset.name)" : "选择\(record.asset.name)")

            HStack(spacing: 8) {
                Text(record.asset.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "star.fill")
                    .foregroundStyle(GraphiteTheme.star)
                    .accessibilityLabel("五星资产")
            }

            Text(record.sourceProjectNames.joined(separator: "、"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Button("Finder", systemImage: "folder", action: onReveal)
                Button("复制路径", systemImage: "doc.on.doc", action: onCopyPath)
                Spacer(minLength: 0)
                if let projectActionTitle {
                    Button(projectActionTitle, systemImage: "folder.badge.plus", action: onProjectAction)
                        .labelStyle(.iconOnly)
                        .help(projectActionTitle)
                } else {
                    Label("本项目资产", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(10)
        .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contextMenu {
            Button("高清原图预览", systemImage: "arrow.up.left.and.arrow.down.right", action: onPreview)
            Button("复制原图", systemImage: "photo.on.rectangle", action: onCopyOriginalImage)
            Button("在 Finder 中显示", systemImage: "folder", action: onReveal)
            Button("复制文件路径", systemImage: "doc.on.doc", action: onCopyPath)
            if let projectActionTitle {
                Divider()
                Button(projectActionTitle, systemImage: "folder.badge.plus", action: onProjectAction)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
