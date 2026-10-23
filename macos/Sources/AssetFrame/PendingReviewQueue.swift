import Foundation

struct PendingReviewQueue: Equatable, Sendable {
    private(set) var itemIDs: [String]
    private(set) var currentID: String?

    init(itemIDs: [String] = [], preferredID: String? = nil) {
        self.itemIDs = Self.unique(itemIDs)
        currentID = preferredID.flatMap { self.itemIDs.contains($0) ? $0 : nil } ?? self.itemIDs.first
    }

    var currentIndex: Int? {
        currentID.flatMap { itemIDs.firstIndex(of: $0) }
    }

    mutating func select(_ id: String) {
        guard itemIDs.contains(id) else { return }
        currentID = id
    }

    mutating func selectPrevious() {
        guard let currentIndex, currentIndex > 0 else { return }
        currentID = itemIDs[currentIndex - 1]
    }

    mutating func selectNext() {
        guard let currentIndex, currentIndex + 1 < itemIDs.count else { return }
        currentID = itemIDs[currentIndex + 1]
    }

    mutating func remove(_ id: String) {
        guard let removedIndex = itemIDs.firstIndex(of: id) else { return }
        itemIDs.remove(at: removedIndex)
        guard currentID == id else { return }
        if itemIDs.indices.contains(removedIndex) {
            currentID = itemIDs[removedIndex]
        } else {
            currentID = itemIDs.last
        }
    }

    mutating func replaceItems(with values: [String], preferredID: String? = nil) {
        let previousID = currentID
        let previousIndex = currentIndex ?? 0
        itemIDs = Self.unique(values)
        if let previousID, itemIDs.contains(previousID) {
            currentID = previousID
        } else if let preferredID, itemIDs.contains(preferredID) {
            currentID = preferredID
        } else if itemIDs.indices.contains(previousIndex) {
            currentID = itemIDs[previousIndex]
        } else {
            currentID = itemIDs.last
        }
    }

    mutating func reconcile(availableIDs: [String], appendingNewItems: Bool) {
        let available = Set(availableIDs)
        let previousID = currentID
        let previousIndex = currentIndex ?? 0
        itemIDs.removeAll { !available.contains($0) }
        if appendingNewItems {
            let existing = Set(itemIDs)
            itemIDs.append(contentsOf: availableIDs.filter { !existing.contains($0) })
        }
        if let previousID, itemIDs.contains(previousID) {
            currentID = previousID
        } else if itemIDs.indices.contains(previousIndex) {
            currentID = itemIDs[previousIndex]
        } else {
            currentID = itemIDs.last
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
