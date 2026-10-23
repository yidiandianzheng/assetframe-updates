import Foundation

struct GallerySelectionController: Equatable {
    private(set) var visibleIDs: [String]
    private(set) var selectedIDs: Set<String>
    private(set) var primaryID: String?
    private(set) var previewID: String?

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

    mutating func reconcile(visibleIDs: [String]) {
        self.visibleIDs = visibleIDs
        let visible = Set(visibleIDs)
        selectedIDs.formIntersection(visible)
        if let primaryID, !visible.contains(primaryID) { self.primaryID = nil }
        if let previewID, !visible.contains(previewID) { self.previewID = nil }
        if self.primaryID == nil, selectedIDs.count == 1 {
            self.primaryID = selectedIDs.first
        }
    }

    mutating func select(_ ids: Set<String>, primaryID: String? = nil) {
        let visible = Set(visibleIDs)
        selectedIDs = ids.intersection(visible)
        self.primaryID = primaryID.flatMap(visible.contains) == true ? primaryID : selectedIDs.first
    }

    mutating func preview(_ id: String?) {
        guard let id, visibleIDs.contains(id) else {
            previewID = nil
            return
        }
        previewID = id
        selectedIDs = [id]
        primaryID = id
    }

    mutating func clearForContextChange(visibleIDs: [String] = []) {
        self.visibleIDs = visibleIDs
        selectedIDs.removeAll()
        primaryID = nil
        previewID = nil
    }

    var canDeleteSelection: Bool { !selectedIDs.isEmpty }
}
