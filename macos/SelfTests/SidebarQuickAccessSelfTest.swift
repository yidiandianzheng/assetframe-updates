import Foundation

@main
struct SidebarQuickAccessSelfTest {
    static func main() {
        let root = SidebarQuickAccessItem(projectID: "P1", sourceID: "S1", relativePath: "")
        let child = SidebarQuickAccessItem(projectID: "P1", sourceID: "S1", relativePath: "人物/主角")
        let otherProject = SidebarQuickAccessItem(projectID: "P2", sourceID: "S1", relativePath: "人物")

        var items = SidebarQuickAccessCodec.toggling(root, in: [])
        precondition(items == [root])
        items = SidebarQuickAccessCodec.toggling(child, in: items)
        precondition(items == [root, child])
        items = SidebarQuickAccessCodec.moving(child.id, by: -1, in: items)
        precondition(items == [child, root])
        items = SidebarQuickAccessCodec.moving(root.id, before: child.id, in: items)
        precondition(items == [root, child])

        let encoded = SidebarQuickAccessCodec.encode(items + [otherProject])
        precondition(SidebarQuickAccessCodec.decode(encoded) == items + [otherProject])

        let renamed = SidebarQuickAccessCodec.replacingRenamedPath(
            projectID: "P1",
            sourceID: "S1",
            oldPath: "人物",
            newPath: "角色",
            in: [child, otherProject]
        )
        precondition(renamed[0].relativePath == "角色/主角")
        precondition(renamed[1] == otherProject)

        precondition(SidebarSearchMatcher.matches("主角", candidates: ["人物/主角"]))
        precondition(!SidebarSearchMatcher.matches("场景", candidates: ["人物/主角"]))
        print("SidebarQuickAccessSelfTest passed")
    }
}
