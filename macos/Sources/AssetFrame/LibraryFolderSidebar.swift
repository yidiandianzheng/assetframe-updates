import SwiftUI

/// The visible organization model is the real directory hierarchy plus filters.
struct LibraryFolderSidebar: View {
    let folders: [LocalFolderSource]
    let materials: [MaterialRecord]
    let revision: Int
    @Binding var scope: String
    @Binding var expandedPaths: Set<String>
    @State private var counts: [String: Int] = [:]

    var body: some View {
        ForEach(folders) { folder in
            let root = URL(fileURLWithPath: folder.rootPath).standardizedFileURL.path
            let paths = LocalFolderTreeLayout.includingAncestors(folder.directoryPaths)
            folderRow(name: folder.name, path: root, depth: 0, hasChildren: !paths.isEmpty)
            if expandedPaths.contains(root) {
                let expanded = Set(paths.filter { expandedPaths.contains(URL(fileURLWithPath: root).appendingPathComponent($0).path) })
                ForEach(LocalFolderTreeLayout.visibleRows(directoryPaths: paths, expandedPaths: expanded)) { row in
                    folderRow(name: row.name, path: URL(fileURLWithPath: root).appendingPathComponent(row.relativePath).path,
                              depth: row.depth + 1, hasChildren: row.hasChildren)
                }
            }
        }
        .task(id: revision) {
            let paths = materials.filter { $0.deletedAt == nil }.compactMap(\.sourcePath)
            let computed = await Task.detached(priority: .utility) {
                LocalFolderTreeLayout.recursiveMaterialCounts(filePaths: paths)
            }.value
            guard !Task.isCancelled else { return }
            counts = computed
        }
    }

    private func folderRow(name: String, path: String, depth: Int, hasChildren: Bool) -> some View {
        HStack(spacing: 4) {
            if hasChildren {
                Button {
                    if !expandedPaths.insert(path).inserted { expandedPaths.remove(path) }
                } label: {
                    Image(systemName: expandedPaths.contains(path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 24)
                }.buttonStyle(.plain)
                    .accessibilityLabel((expandedPaths.contains(path) ? "收起 " : "展开 ") + name)
            } else { Color.clear.frame(width: 14, height: 24) }
            Button { scope = "path:" + path } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(counts[path].map(String.init) ?? "0")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(path + "\n素材数量包含子文件夹，不含回收站")
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.trailing, 6)
        .background(scope == "path:" + path ? Color.accentColor.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }
}
