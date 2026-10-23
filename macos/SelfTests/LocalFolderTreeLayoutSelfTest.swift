import Foundation

@main
struct LocalFolderTreeLayoutSelfTest {
    static func main() {
        let paths = [
            "",
            "人物",
            "人物/顾长宁",
            "人物/顾长宁/四视图",
            "人物/顾长宁/四视图/正面",
            "场景",
            "场景/空目录"
        ]

        precondition(LocalFolderTreeLayout.hasRootChildren(paths), "资料库根目录有下级文件夹时必须显示展开箭头")
        precondition(!LocalFolderTreeLayout.hasRootChildren([""]), "没有下级文件夹时不得显示空箭头")

        let initiallyExpanded = LocalFolderTreeLayout.initialExpandedPaths(paths)
        precondition(initiallyExpanded.isEmpty, "默认只显示资料库根目录下的第二级文件夹")
        let initialRows = LocalFolderTreeLayout.visibleRows(
            directoryPaths: paths,
            expandedPaths: initiallyExpanded
        )
        precondition(Set(initialRows.map(\.relativePath)) == Set(["人物", "场景"]))
        precondition(!initialRows.contains(where: { $0.relativePath == "人物/顾长宁" }), "第三级及更深目录默认隐藏")

        let focusedRows = LocalFolderTreeLayout.focusedCategoryRows(directoryPaths: paths)
        precondition(Set(focusedRows.map(\.relativePath)) == Set(["人物", "场景"]), "层级浏览默认应只显示资料库的一级分类")
        precondition(focusedRows.allSatisfy { $0.depth == 0 })

        let searchRows = LocalFolderTreeLayout.searchRows(directoryPaths: paths, query: "顾长宁")
        precondition(searchRows.map(\.relativePath) == ["人物", "人物/顾长宁", "人物/顾长宁/四视图", "人物/顾长宁/四视图/正面"])
        precondition(searchRows.map(\.depth) == [0, 1, 2, 3])

        var manuallyExpanded = initiallyExpanded
        manuallyExpanded.insert("人物")
        manuallyExpanded.insert("人物/顾长宁")
        manuallyExpanded.insert("场景")
        let expandedRows = LocalFolderTreeLayout.visibleRows(
            directoryPaths: paths,
            expandedPaths: manuallyExpanded
        )
        precondition(expandedRows.contains(where: { $0.relativePath == "人物/顾长宁/四视图" }))
        precondition(!expandedRows.contains(where: { $0.relativePath == "人物/顾长宁/四视图/正面" }))

        var collapsed = manuallyExpanded
        collapsed.remove("人物")
        let collapsedRows = LocalFolderTreeLayout.visibleRows(
            directoryPaths: paths,
            expandedPaths: collapsed
        )
        precondition(collapsedRows.contains(where: { $0.relativePath == "人物" }))
        precondition(!collapsedRows.contains(where: { $0.relativePath == "人物/顾长宁" }))
        precondition(collapsedRows.contains(where: { $0.relativePath == "场景/空目录" }), "折叠一个分支不得影响兄弟分支")

        let refreshedPaths = paths + [
            "人物/顾长宁/新增",
            "人物/顾长宁/新增/表情",
            "道具",
            "道具/茶壶"
        ]
        let reconciled = LocalFolderTreeLayout.reconcileExpandedPaths(
            collapsed,
            oldDirectoryPaths: paths,
            newDirectoryPaths: refreshedPaths
        )
        precondition(!reconciled.contains("人物"), "刷新不得重新打开用户已折叠的旧分支")
        precondition(reconciled.contains("人物/顾长宁"), "刷新应保留旧目录的手动展开状态")
        precondition(!reconciled.contains("人物/顾长宁/新增"), "新发现的深层目录默认保持收起")
        precondition(!reconciled.contains("道具"), "新发现的第二级目录也应默认收起")

        let restoredRows = LocalFolderTreeLayout.visibleRows(
            directoryPaths: refreshedPaths,
            expandedPaths: reconciled.union(["人物"])
        )
        precondition(restoredRows.contains(where: { $0.relativePath == "人物/顾长宁/新增" }))
        precondition(!restoredRows.contains(where: { $0.relativePath == "人物/顾长宁/新增/表情" }))
        precondition(restoredRows.contains(where: { $0.relativePath == "道具" }))
        precondition(!restoredRows.contains(where: { $0.relativePath == "道具/茶壶" }))

        let completed = LocalFolderTreeLayout.includingAncestors(["人物/A/3D", "人物/B", "../错误", "", "人物/A/3D"])
        precondition(Set(completed) == ["人物", "人物/A", "人物/A/3D", "人物/B"])
        let top = LocalFolderTreeLayout.visibleRows(directoryPaths: completed, expandedPaths: [])
        precondition(top.map(\.name) == ["人物"])
        let nested = LocalFolderTreeLayout.visibleRows(directoryPaths: completed, expandedPaths: ["人物", "人物/A"])
        precondition(nested.map(\.name) == ["人物", "A", "3D", "B"])
        precondition(nested.map(\.depth) == [0, 1, 2, 1])
        let counts = LocalFolderTreeLayout.recursiveMaterialCounts(filePaths: [
            "/库/人物/A/a.png", "/库/人物/A/b.wav", "/库/人物/B/c.mp4", "/库/人物2/d.png"
        ])
        precondition(counts["/库/人物"] == 3 && counts["/库/人物/A"] == 2)
        precondition(counts["/库/人物2"] == 1 && counts["/库"] == 4)
        print("LocalFolderTreeLayoutSelfTest passed: hierarchy, collapse, ancestors, recursive counts, sibling boundaries")
    }
}
