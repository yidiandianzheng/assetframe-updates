import AppKit
import SwiftUI

struct GalleryChildFolderSection: View {
    let folders: [GalleryChildFolder]
    @Binding var folderScope: LocalFolderScope
    let onSelect: (LocalFolderSelection) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? "收起子文件夹" : "展开子文件夹")

                Text("子文件夹（\(folders.count)）")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Toggle("显示子文件夹内容", isOn: showsChildFolderContents)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("关闭后下方只显示当前文件夹直属图片")
            }
            .padding(.horizontal, 16)
            .frame(height: 36)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(folders) { folder in
                            GalleryChildFolderCard(folder: folder) {
                                onSelect(LocalFolderSelection(
                                    sourceID: folder.sourceID,
                                    relativePath: folder.relativePath
                                ))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .frame(height: 158)
            }
        }
        .background(GraphiteTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("子文件夹")
    }

    private var showsChildFolderContents: Binding<Bool> {
        Binding(
            get: { folderScope != .currentOnly },
            set: { folderScope = $0 ? .recursive : .currentOnly }
        )
    }
}

private struct GalleryChildFolderCard: View {
    let folder: GalleryChildFolder
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                GalleryChildFolderCover(asset: folder.coverAsset)
                    .frame(width: 152, height: 94)

                Text(folder.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 152, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开“\(folder.name)”")
        .accessibilityLabel("\(folder.name)，\(detailText)，进入子文件夹")
    }

    private var detailText: String {
        if folder.childFolderCount > 0 {
            return "\(folder.directFileCount) 个文件 · \(folder.childFolderCount) 个子文件夹"
        }
        return "\(folder.directFileCount) 个文件"
    }
}

private struct GalleryChildFolderCover: View {
    let asset: AssetItem?
    @State private var image: NSImage?
    @State private var requestID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(GraphiteTheme.card)
                .frame(width: 64, height: 14)
                .offset(x: 7, y: -5)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(GraphiteTheme.card)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 31, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear(perform: load)
        .onChange(of: identity) { _, _ in load() }
        .onDisappear {
            ThumbnailPipeline.shared.cancel(requestID)
            requestID = nil
        }
    }

    private var identity: String {
        guard let asset else { return "empty" }
        return "\(asset.imagePath)|\(asset.sourceModifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func load() {
        ThumbnailPipeline.shared.cancel(requestID)
        requestID = nil
        image = nil
        guard let asset else { return }
        requestID = ThumbnailPipeline.shared.request(
            asset: asset,
            size: CGSize(width: 304, height: 188)
        ) { loaded in
            image = loaded
        }
    }
}
