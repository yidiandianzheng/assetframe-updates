import Foundation

@main
struct GalleryChildFolderResolverSelfTest {
    static func main() {
        let paths = [
            "",
            "人物",
            "人物/主角",
            "人物/主角/正面",
            "人物/配角",
            "场景",
            "人物/10组",
            "人物/2组",
            "/道具/",
            "道具"
        ]

        let rootChildren = GalleryChildFolderResolver.directChildren(directoryPaths: paths, parentPath: "")
        precondition(Set(rootChildren) == Set(["人物", "场景", "道具"]), "根目录必须只返回直属子文件夹并去重")
        precondition(rootChildren.count == 3, "前后斜线归一化后不得出现重复目录")

        let personChildren = GalleryChildFolderResolver.directChildren(
            directoryPaths: paths,
            parentPath: "人物"
        )
        precondition(Set(personChildren) == Set(["人物/2组", "人物/10组", "人物/主角", "人物/配角"]))
        precondition(
            personChildren.firstIndex(of: "人物/2组")! < personChildren.firstIndex(of: "人物/10组")!,
            "数字目录名应使用本地化自然排序"
        )
        precondition(!personChildren.contains("人物/主角/正面"), "孙级目录不得冒充直属子目录")

        precondition(
            GalleryChildFolderResolver.directChildren(directoryPaths: paths, parentPath: "/人物/主角/") == ["人物/主角/正面"],
            "父路径前后斜线不应影响结果"
        )
        precondition(
            GalleryChildFolderResolver.directChildren(directoryPaths: paths, parentPath: "不存在").isEmpty,
            "没有子目录时应返回空数组"
        )

        print("GalleryChildFolderResolverSelfTest passed")
    }
}
