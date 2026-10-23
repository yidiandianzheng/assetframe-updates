import SwiftUI

struct LocalFolderAssetDropDelegate: DropDelegate {
    let store: AssetStore
    let destination: LocalFolderSelection
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [AssetDragPasteboard.identifier])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }

    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [AssetDragPasteboard.identifier]).first else {
            isTargeted = false
            return false
        }
        isTargeted = false
        provider.loadDataRepresentation(forTypeIdentifier: AssetDragPasteboard.identifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(AssetDragPayload.self, from: data) else { return }
            Task { @MainActor in
                store.moveGalleryAssets(
                    payload.allAssetIDs,
                    fromProjectID: payload.projectID,
                    toLocalFolder: destination.sourceID,
                    relativePath: destination.relativePath
                )
            }
        }
        return true
    }
}
