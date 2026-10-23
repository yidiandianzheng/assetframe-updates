import SwiftUI

struct PinnedFolderQuickAccessSection: View {
    let items: [SidebarQuickAccessItem]
    let folders: [LocalFolderSource]
    let selectedFolder: LocalFolderSelection?
    let searchQuery: String
    let onSelect: (SidebarQuickAccessItem) -> Void
    let onRemove: (SidebarQuickAccessItem) -> Void
    let onMove: (String, Int) -> Void
    let onReorder: (String, String) -> Void

    private var visibleItems: [SidebarQuickAccessItem] {
        items.filter { item in
            let folder = folders.first { $0.id == item.sourceID }
            return SidebarSearchMatcher.matches(
                searchQuery,
                candidates: [item.displayName, folder?.sidebarDisplayName ?? "", item.relativePath]
            )
        }
    }

    var body: some View {
        if !visibleItems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("快速访问")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.top, 2)

                ForEach(visibleItems) { item in
                    row(for: item)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 5)
        }
    }

    private func row(for item: SidebarQuickAccessItem) -> some View {
        let folder = folders.first { $0.id == item.sourceID }
        let selection = LocalFolderSelection(sourceID: item.sourceID, relativePath: item.relativePath)
        let isSelected = selectedFolder == selection
        let index = items.firstIndex(of: item) ?? 0
        let isAvailable = folder.map { item.relativePath.isEmpty || $0.directoryPaths.contains(item.relativePath) } ?? false

        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isAvailable ? "pin.fill" : "pin.slash")
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.relativePath.isEmpty ? (folder?.sidebarDisplayName ?? item.displayName) : item.displayName)
                        .lineLimit(1)
                    if !item.relativePath.isEmpty {
                        Text(folder?.sidebarDisplayName ?? "来源不可用")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.13) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .draggable(item.id)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let sourceID = droppedIDs.first else { return false }
            onReorder(sourceID, item.id)
            return true
        }
        .contextMenu {
            Button("向上移动", systemImage: "arrow.up", action: { onMove(item.id, -1) })
                .disabled(index == 0)
            Button("向下移动", systemImage: "arrow.down", action: { onMove(item.id, 1) })
                .disabled(index + 1 >= items.count)
            Divider()
            Button("从快速访问移除", systemImage: "pin.slash", action: { onRemove(item) })
        }
        .help(isAvailable ? item.relativePath : "原文件夹已移动、重命名或磁盘未连接")
    }
}
