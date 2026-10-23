import AppKit

@main
@MainActor
struct GallerySnapshotSelfTest {
    static func main() {
        let populated = GallerySnapshotBuilder.make(itemIDs: ["A", "B", "A", "C"])
        precondition(populated.sectionIdentifiers == [GallerySnapshotBuilder.sectionID])
        precondition(populated.itemIdentifiers == ["A", "B", "C"])

        let empty = GallerySnapshotBuilder.make(itemIDs: [])
        precondition(empty.sectionIdentifiers == [GallerySnapshotBuilder.sectionID])
        precondition(empty.itemIdentifiers.isEmpty)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        let dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { _, _, _ in nil }
        for index in 0..<1_000 {
            let ids = index.isMultiple(of: 2) ? ["A", "B", "C"] : []
            let snapshot = GallerySnapshotBuilder.make(itemIDs: ids)
            precondition(snapshot.sectionIdentifiers == [GallerySnapshotBuilder.sectionID])
            precondition(snapshot.itemIdentifiers == ids)
            dataSource.apply(snapshot, animatingDifferences: false)
            precondition(dataSource.snapshot().itemIdentifiers == ids)
        }

        print("GallerySnapshotSelfTest passed")
    }
}
