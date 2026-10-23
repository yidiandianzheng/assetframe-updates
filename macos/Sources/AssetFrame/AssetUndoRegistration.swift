import AppKit

@MainActor
enum AssetUndoRegistration {
    static func registerTrashUndo(
        manager: UndoManager?,
        store: AssetStore,
        assetIDs: Set<String>,
        restoresOnInvoke: Bool = true
    ) {
        guard let manager, !assetIDs.isEmpty else { return }
        manager.registerUndo(withTarget: store) { target in
            if restoresOnInvoke {
                target.restoreAssets(assetIDs)
            } else {
                target.moveAssetsToTrash(assetIDs)
            }
            registerTrashUndo(
                manager: manager,
                store: target,
                assetIDs: assetIDs,
                restoresOnInvoke: !restoresOnInvoke
            )
        }
        manager.setActionName(restoresOnInvoke ? "移入 AssetFrame 回收站" : "恢复 AssetFrame 资产")
    }
}

