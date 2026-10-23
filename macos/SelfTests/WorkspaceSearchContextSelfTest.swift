import Foundation

@main
struct WorkspaceSearchContextSelfTest {
    static func main() {
        precondition(WorkspaceSearchContext.assets.supportsSearch)
        precondition(WorkspaceSearchContext.globalFiveStar.supportsSearch)
        precondition(WorkspaceSearchContext.materials.supportsSearch)
        precondition(!WorkspaceSearchContext.unsupported.supportsSearch)
        print("WorkspaceSearchContextSelfTest passed")
    }
}
