import Foundation

@main
struct GallerySelectionControllerSelfTest {
    static func main() {
        var controller = GallerySelectionController(
            visibleIDs: ["A", "B", "C"],
            selectedIDs: ["A", "hidden"],
            primaryID: "hidden",
            previewID: "B"
        )
        precondition(controller.selectedIDs == ["A"])
        precondition(controller.primaryID == "A")
        precondition(controller.previewID == "B")

        controller.reconcile(visibleIDs: ["C"])
        precondition(controller.selectedIDs.isEmpty)
        precondition(controller.primaryID == nil)
        precondition(controller.previewID == nil)

        controller.select(["C", "hidden"], primaryID: "C")
        precondition(controller.selectedIDs == ["C"] && controller.primaryID == "C")
        controller.preview("C")
        precondition(controller.previewID == "C" && controller.selectedIDs == ["C"])
        controller.clearForContextChange(visibleIDs: ["D"])
        precondition(controller.visibleIDs == ["D"] && controller.selectedIDs.isEmpty)
        print("GallerySelectionControllerSelfTest passed")
    }
}
