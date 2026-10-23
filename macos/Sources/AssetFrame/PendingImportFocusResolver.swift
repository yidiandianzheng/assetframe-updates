import Foundation

enum PendingImportFocusResolver {
    static func resolve(
        previousSelection: Set<String>,
        selection: Set<String>,
        currentFocus: String?,
        orderedIDs: [String]
    ) -> String? {
        if let newlySelected = orderedIDs.first(where: {
            selection.contains($0) && !previousSelection.contains($0)
        }) {
            return newlySelected
        }
        if let currentFocus, selection.contains(currentFocus) {
            return currentFocus
        }
        return orderedIDs.first(where: selection.contains)
    }

    static func reconcile(currentFocus: String?, availableIDs: Set<String>) -> String? {
        guard let currentFocus, availableIDs.contains(currentFocus) else { return nil }
        return currentFocus
    }
}
