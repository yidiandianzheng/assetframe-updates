import Foundation

struct GalleryChildFolder: Identifiable {
    var id: String { "\(sourceID)|\(relativePath)" }
    let sourceID: String
    let name: String
    let relativePath: String
    let directFileCount: Int
    let childFolderCount: Int
    let coverAsset: AssetItem?
}

enum GalleryChildFolderResolver {
    static func directChildren(
        directoryPaths: [String],
        parentPath: String
    ) -> [String] {
        let parent = normalized(parentPath)
        let paths = Set(directoryPaths.map(normalized).filter { !$0.isEmpty })
        return paths
            .filter { path in
                let candidateParent = (path as NSString).deletingLastPathComponent
                return (candidateParent == "." ? "" : candidateParent) == parent
            }
            .sorted {
                let result = $0.localizedStandardCompare($1)
                return result == .orderedSame ? $0 < $1 : result == .orderedAscending
            }
    }

    private static func normalized(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }
}
