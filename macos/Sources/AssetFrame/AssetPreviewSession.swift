import Foundation

/// 预览中的一个固定位置。裁定状态在打开窗口时快照；预览只允许回写组图首选项。
struct AssetPreviewItem: Identifiable, Hashable, Sendable {
    let asset: AssetItem
    let decision: VariantCandidateDecision?

    var id: String { asset.id }
    var statusText: String {
        switch decision {
        case .main: "主图"
        case .reference: "补图"
        case .unused: "淘汰"
        case .pending: "待裁定"
        case nil: asset.decision.displayName
        }
    }
}

/// 单图和组图共用的预览会话。组图首选项置顶，其余候选保持 `memberAssetIDs` 相对顺序。
struct AssetPreviewSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let projectID: String
    let groupID: String?
    let title: String
    let items: [AssetPreviewItem]
    let initialIndex: Int
    let preferredAssetID: String?

    var isGroup: Bool { groupID != nil }

    static func single(asset: AssetItem, projectID: String) -> AssetPreviewSession {
        AssetPreviewSession(
            id: UUID(),
            projectID: projectID,
            groupID: nil,
            title: asset.name,
            items: [AssetPreviewItem(asset: asset, decision: nil)],
            initialIndex: 0,
            preferredAssetID: nil
        )
    }

    static func group(
        stack: AssetStack,
        assets: [AssetItem],
        projectID: String
    ) -> AssetPreviewSession? {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var seen: Set<String> = []
        let memberItems = stack.memberAssetIDs.compactMap { assetID -> AssetPreviewItem? in
            guard seen.insert(assetID).inserted,
                  let asset = assetsByID[assetID],
                  asset.deletedAt == nil else { return nil }
            return AssetPreviewItem(
                asset: asset,
                decision: stack.decisions[assetID, default: .pending]
            )
        }
        guard !memberItems.isEmpty else { return nil }

        let preferredID: String
        if memberItems.contains(where: { $0.id == stack.coverAssetID }) {
            preferredID = stack.coverAssetID
        } else if let mainAssetID = stack.mainAssetID,
                  memberItems.contains(where: { $0.id == mainAssetID }) {
            preferredID = mainAssetID
        } else {
            preferredID = memberItems[0].id
        }
        let displayedItems = promotingPreferred(preferredID, in: memberItems)

        return AssetPreviewSession(
            id: UUID(),
            projectID: projectID,
            groupID: stack.id,
            title: stack.name,
            items: displayedItems,
            initialIndex: 0,
            preferredAssetID: preferredID
        )
    }

    /// 只调整预览顺序，不改写形态组持久化的候选顺序。
    static func promotingPreferred(
        _ preferredAssetID: String?,
        in items: [AssetPreviewItem]
    ) -> [AssetPreviewItem] {
        guard let preferredAssetID,
              let preferredIndex = items.firstIndex(where: { $0.id == preferredAssetID }),
              preferredIndex != items.startIndex else { return items }
        var reordered = items
        let preferred = reordered.remove(at: preferredIndex)
        reordered.insert(preferred, at: 0)
        return reordered
    }
}
