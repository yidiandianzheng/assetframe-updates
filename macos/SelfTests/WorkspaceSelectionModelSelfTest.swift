import Foundation

@main
enum WorkspaceSelectionModelSelfTest {
    @MainActor
    static func main() {
        let model = WorkspaceSelectionModel(
            visibleIDs: ["A", "B", "C"],
            selectedIDs: ["A", "hidden"],
            primaryID: "hidden",
            previewID: "B"
        )
        precondition(model.selectedIDs == ["A"])
        precondition(model.primaryID == "A")
        precondition(model.previewID == "B")

        model.select(["A", "B"], primaryID: "B")
        precondition(model.selectedIDs == ["A", "B"])
        precondition(model.primaryID == "B")

        model.preview("C")
        precondition(model.previewID == "C")
        precondition(model.selectedIDs == ["C"])
        precondition(model.primaryID == "C")

        model.reconcile(visibleIDs: ["A", "B"])
        precondition(model.selectedIDs.isEmpty)
        precondition(model.primaryID == nil)
        precondition(model.previewID == nil)

        model.selectPrimary("A")
        model.movePrimary(by: 1)
        precondition(model.primaryID == "B")
        model.movePrimary(by: -1)
        precondition(model.primaryID == "A")
        model.clearForContextChange(visibleIDs: ["D"])
        precondition(model.visibleIDs == ["D"])
        precondition(model.selectedIDs.isEmpty)
        print("WorkspaceSelectionModelSelfTest passed")
    }
}
