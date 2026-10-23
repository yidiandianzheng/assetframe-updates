import Foundation

@main
struct LocalFolderScopeSelfTest {
    static func main() {
        let selected = "人物/主角"
        precondition(LocalFolderScope.currentOnly.includes(directory: selected, selectedDirectory: selected))
        precondition(!LocalFolderScope.currentOnly.includes(directory: "人物/主角/正面", selectedDirectory: selected))

        precondition(LocalFolderScope.oneLevel.includes(directory: selected, selectedDirectory: selected))
        precondition(LocalFolderScope.oneLevel.includes(directory: "人物/主角/正面", selectedDirectory: selected))
        precondition(!LocalFolderScope.oneLevel.includes(directory: "人物/主角/正面/精选", selectedDirectory: selected))

        precondition(LocalFolderScope.recursive.includes(directory: "人物/主角/正面/精选", selectedDirectory: selected))
        precondition(!LocalFolderScope.recursive.includes(directory: "人物/配角", selectedDirectory: selected))

        precondition(LocalFolderScope.currentOnly.includes(directory: "", selectedDirectory: ""))
        precondition(LocalFolderScope.oneLevel.includes(directory: "一级", selectedDirectory: ""))
        precondition(!LocalFolderScope.oneLevel.includes(directory: "一级/二级", selectedDirectory: ""))
        print("LocalFolderScopeSelfTest passed")
    }
}
