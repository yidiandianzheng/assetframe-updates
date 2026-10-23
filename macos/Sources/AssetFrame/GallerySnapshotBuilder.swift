import AppKit

@MainActor
enum GallerySnapshotBuilder {
    static let sectionID = 0

    static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func make(itemIDs: [String]) -> NSDiffableDataSourceSnapshot<Int, String> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([sectionID])
        let uniqueItemIDs = uniqueIDs(itemIDs)
        if !uniqueItemIDs.isEmpty {
            snapshot.appendItems(uniqueItemIDs, toSection: sectionID)
        }
        return snapshot
    }
}
