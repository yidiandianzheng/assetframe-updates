import SwiftUI

/// One source of truth for selection and preview state across gallery-like workspaces.
/// Quick Review intentionally keeps its linear `PendingReviewQueue` instead.
@MainActor
final class WorkspaceSelectionModel: ObservableObject {
    @Published private(set) var visibleIDs: [String]
    @Published private(set) var selectedIDs: Set<String>
    @Published private(set) var primaryID: String?
    @Published private(set) var previewID: String?

    init(
        visibleIDs: [String] = [],
        selectedIDs: Set<String> = [],
        primaryID: String? = nil,
        previewID: String? = nil
    ) {
        self.visibleIDs = visibleIDs
        self.selectedIDs = selectedIDs
        self.primaryID = primaryID
        self.previewID = previewID
        reconcile(visibleIDs: visibleIDs)
    }

    var selectedIDsBinding: Binding<Set<String>> {
        Binding(
            get: { self.selectedIDs },
            set: { self.select($0) }
        )
    }

    var previewIDBinding: Binding<String?> {
        Binding(
            get: { self.previewID },
            set: { self.preview($0) }
        )
    }

    func reconcile(visibleIDs: [String]) {
        var controller = controllerSnapshot
        controller.reconcile(visibleIDs: visibleIDs)
        apply(controller)
    }

    func select(_ ids: Set<String>, primaryID: String? = nil) {
        var controller = controllerSnapshot
        controller.select(ids, primaryID: primaryID)
        apply(controller)
    }

    func selectPrimary(_ id: String?) {
        guard let id else {
            select([])
            return
        }
        select([id], primaryID: id)
    }

    func preview(_ id: String?) {
        var controller = controllerSnapshot
        controller.preview(id)
        apply(controller)
    }

    func closePreview() {
        previewID = nil
    }

    func movePrimary(by offset: Int) {
        guard !visibleIDs.isEmpty, offset != 0 else { return }
        let currentIndex = primaryID.flatMap { visibleIDs.firstIndex(of: $0) }
            ?? (offset > 0 ? -1 : visibleIDs.count)
        let destination = min(max(0, currentIndex + offset), visibleIDs.count - 1)
        selectPrimary(visibleIDs[destination])
    }

    func clearForContextChange(visibleIDs: [String] = []) {
        var controller = controllerSnapshot
        controller.clearForContextChange(visibleIDs: visibleIDs)
        apply(controller)
    }

    func removeFromSelection(_ ids: Set<String>) {
        select(selectedIDs.subtracting(ids), primaryID: primaryID)
    }

    private var controllerSnapshot: GallerySelectionController {
        GallerySelectionController(
            visibleIDs: visibleIDs,
            selectedIDs: selectedIDs,
            primaryID: primaryID,
            previewID: previewID
        )
    }

    private func apply(_ controller: GallerySelectionController) {
        visibleIDs = controller.visibleIDs
        selectedIDs = controller.selectedIDs
        primaryID = controller.primaryID
        previewID = controller.previewID
    }
}
