import Foundation

struct LocalFolderTreeRow: Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    var name: String
    var relativePath: String
    var depth: Int
    var hasChildren: Bool
}

enum LocalFolderTreeLayout {
    /// Some scanners persist only leaf directories. Restore their ancestors for a real tree.
    static func includingAncestors(_ directoryPaths: [String]) -> [String] {
        var paths: Set<String> = []
        for value in directoryPaths {
            let components = value.split(separator: "/").map(String.init)
            guard !components.contains(".."), !value.hasPrefix("/") else { continue }
            var current = ""
            for component in components where component != "." {
                current = current.isEmpty ? component : current + "/" + component
                paths.insert(current)
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Count records, not unique file bytes; parent counts match recursive folder browsing.
    static func recursiveMaterialCounts(filePaths: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for file in filePaths {
            var path = URL(fileURLWithPath: file).standardizedFileURL.deletingLastPathComponent().path
            while !path.isEmpty {
                counts[path, default: 0] += 1
                if path == "/" { break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return counts
    }

    static func hasRootChildren(_ directoryPaths: [String]) -> Bool {
        directoryPaths.contains { !$0.isEmpty }
    }

    static func initialExpandedPaths(_ directoryPaths: [String]) -> Set<String> {
        []
    }

    /// 刷新保留旧目录的手动状态；新目录默认收起，侧栏只显示资料库根目录下的第二级。
    static func reconcileExpandedPaths(
        _ expandedPaths: Set<String>,
        oldDirectoryPaths: [String],
        newDirectoryPaths: [String]
    ) -> Set<String> {
        let newPaths = Set(newDirectoryPaths.filter { !$0.isEmpty })
        return expandedPaths.intersection(newPaths)
    }

    static func visibleRows(
        directoryPaths: [String],
        expandedPaths: Set<String>
    ) -> [LocalFolderTreeRow] {
        let paths = Set(directoryPaths.filter { !$0.isEmpty })
        let childrenByParent = Dictionary(grouping: paths, by: parentPath(of:))
            .mapValues { paths in
                paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        var rows: [LocalFolderTreeRow] = []

        func appendChildren(of parent: String, depth: Int) {
            for path in childrenByParent[parent] ?? [] {
                let hasChildren = !(childrenByParent[path] ?? []).isEmpty
                rows.append(LocalFolderTreeRow(
                    name: (path as NSString).lastPathComponent,
                    relativePath: path,
                    depth: depth,
                    hasChildren: hasChildren
                ))
                if hasChildren, expandedPaths.contains(path) {
                    appendChildren(of: path, depth: depth + 1)
                }
            }
        }

        appendChildren(of: "", depth: 0)
        return rows
    }

    /// 层级浏览默认只显示资料库根目录下的一级分类，再由用户逐层展开。
    static func focusedCategoryRows(directoryPaths: [String]) -> [LocalFolderTreeRow] {
        visibleRows(directoryPaths: directoryPaths, expandedPaths: [])
    }

    /// 搜索时同时保留命中项的祖先路径，让结果仍然具有可理解的目录层级。
    static func searchRows(directoryPaths: [String], query: String) -> [LocalFolderTreeRow] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let paths = Set(directoryPaths.filter { !$0.isEmpty })
        let matches = paths.filter { path in
            path.split(separator: "/").contains { component in
                String(component).localizedStandardContains(normalized)
            }
        }
        var visiblePaths = matches
        for match in matches {
            var parent = parentPath(of: match)
            while !parent.isEmpty {
                visiblePaths.insert(parent)
                parent = parentPath(of: parent)
            }
        }
        return visiblePaths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            LocalFolderTreeRow(
                name: (path as NSString).lastPathComponent,
                relativePath: path,
                depth: depth(of: path),
                hasChildren: visiblePaths.contains { parentPath(of: $0) == path }
            )
        }
    }

    private static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private static func depth(of path: String) -> Int {
        max(0, path.split(separator: "/").count - 1)
    }
}
