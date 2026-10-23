import Foundation

struct PendingReviewTypeSelection: Equatable, Sendable {
    private(set) var selectedTypes: Set<AssetType> = []

    var isActive: Bool {
        !selectedTypes.isEmpty
    }

    mutating func toggle(_ type: AssetType) {
        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
    }

    mutating func selectOnly(_ type: AssetType) {
        selectedTypes = [type]
    }

    mutating func clear() {
        selectedTypes.removeAll()
    }

    func includes(_ item: PendingImportItem) -> Bool {
        !isActive || selectedTypes.contains(item.suggestedType)
    }
}
