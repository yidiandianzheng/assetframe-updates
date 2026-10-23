import SwiftUI

struct GlobalFiveStarSelectionBar: View {
    @ObservedObject var store: GlobalFiveStarStore
    let records: [GlobalFiveStarRecord]
    let project: ProjectRecord
    let clearSelection: () -> Void

    private var linkableIDs: Set<String> {
        Set(records.lazy.filter {
            !$0.isOwned(by: project.id) && !store.isLinked($0.id, to: project.id)
        }.map(\.id))
    }
    private var removableLinkIDs: Set<String> {
        Set(records.lazy.filter {
            !$0.isOwned(by: project.id) && store.isLinked($0.id, to: project.id)
        }.map(\.id))
    }

    var body: some View {
        ResponsiveCommandBar {
            expandedBar
        } compact: {
            compactBar
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var expandedBar: some View {
        HStack(spacing: 10) {
            Label("已选 \(records.count) 项", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
            if records.count == 1, let record = records.first {
                Divider().frame(height: 18)
                Text(record.sourceProjectNames.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("预览", systemImage: "arrow.up.left.and.arrow.down.right", action: preview)
                Button("Finder", systemImage: "folder", action: reveal)
                Button("复制原图", systemImage: "photo.on.rectangle", action: copyOriginalImage)
                Button("复制路径", systemImage: "doc.on.doc", action: copyPath)
            }
            if !linkableIDs.isEmpty {
                Button("引用到当前项目 \(linkableIDs.count) 项", systemImage: "folder.badge.plus", action: addLinks)
            }
            if !removableLinkIDs.isEmpty {
                Button("取消项目引用 \(removableLinkIDs.count) 项", systemImage: "folder.badge.minus", action: removeLinks)
            }
            Spacer()
            Button("取消选择", action: clearSelection)
                .buttonStyle(.borderless)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            Label("已选 \(records.count) 项", systemImage: "checkmark.circle.fill")
            Menu("所选操作", systemImage: "ellipsis.circle") {
                if records.count == 1 {
                    Button("预览", systemImage: "arrow.up.left.and.arrow.down.right", action: preview)
                    Button("Finder", systemImage: "folder", action: reveal)
                    Button("复制原图", systemImage: "photo.on.rectangle", action: copyOriginalImage)
                    Button("复制路径", systemImage: "doc.on.doc", action: copyPath)
                }
                if !linkableIDs.isEmpty {
                    Button("引用到当前项目 \(linkableIDs.count) 项", systemImage: "folder.badge.plus", action: addLinks)
                }
                if !removableLinkIDs.isEmpty {
                    Button("取消项目引用 \(removableLinkIDs.count) 项", systemImage: "folder.badge.minus", action: removeLinks)
                }
            }
            Spacer()
            Button("取消选择", action: clearSelection).buttonStyle(.borderless)
        }
    }

    private func preview() {
        guard let record = records.first else { return }
        AssetPreviewWindowController.shared.show(asset: record.asset)
    }

    private func reveal() {
        guard let record = records.first else { return }
        store.reveal(record)
    }

    private func copyPath() {
        guard let record = records.first else { return }
        store.copyPath(record)
    }

    private func copyOriginalImage() {
        guard let record = records.first else { return }
        store.copyOriginalImage(record)
    }

    private func addLinks() { store.addLinks(recordIDs: linkableIDs, projectID: project.id) }
    private func removeLinks() { store.removeLinks(recordIDs: removableLinkIDs, projectID: project.id) }
}
