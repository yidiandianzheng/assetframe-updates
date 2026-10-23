import Foundation

enum AssetRemovalRoute: String, Equatable {
    case appTrash
    case discardPending
    case systemTrashAfterIdentityCheck
}

struct AssetRemovalActionDescriptor: Identifiable, Equatable {
    let route: AssetRemovalRoute
    let itemIDs: Set<String>
    let title: String
    let confirmationTitle: String
    let confirmationMessage: String

    var id: String { route.rawValue }
    var count: Int { itemIDs.count }
}

struct AssetRemovalPlan: Equatable {
    let actions: [AssetRemovalActionDescriptor]

    init(targets: Set<AssetActionTarget>) {
        self.init(
            formalIDs: Set(targets.compactMap { if case .formal(let id) = $0 { id } else { nil } }),
            pendingIDs: Set(targets.compactMap { if case .pending(let id) = $0 { id } else { nil } }),
            quickReviewIDs: Set(targets.compactMap { if case .quickReview(let id) = $0 { id } else { nil } })
        )
    }

    init(formalIDs: Set<String>, pendingIDs: Set<String>, quickReviewIDs: Set<String> = []) {
        var actions: [AssetRemovalActionDescriptor] = []
        if !formalIDs.isEmpty {
            actions.append(AssetRemovalActionDescriptor(
                route: .appTrash,
                itemIDs: formalIDs,
                title: "移入回收站 \(formalIDs.count) 项",
                confirmationTitle: "将正式资产移入 App 回收站？",
                confirmationMessage: "正式资产记录会进入可恢复的 App 回收站；原图不会移动或删除。"
            ))
        }
        if !pendingIDs.isEmpty {
            actions.append(AssetRemovalActionDescriptor(
                route: .discardPending,
                itemIDs: pendingIDs,
                title: "移出待确认 \(pendingIDs.count) 项",
                confirmationTitle: "将素材移出待确认？",
                confirmationMessage: "只移除待确认记录；原文件保留在当前位置，不会创建回收站资产。"
            ))
        }
        if !quickReviewIDs.isEmpty {
            actions.append(AssetRemovalActionDescriptor(
                route: .systemTrashAfterIdentityCheck,
                itemIDs: quickReviewIDs,
                title: "移到系统废纸篓 \(quickReviewIDs.count) 项",
                confirmationTitle: "删除已标记的废片？",
                confirmationMessage: "会先核验文件大小和修改时间，仅将身份仍匹配的原文件移到 macOS 废纸篓。"
            ))
        }
        self.actions = actions
    }

    var totalCount: Int { actions.reduce(0) { $0 + $1.count } }
    var requiresSummaryConfirmation: Bool { actions.count > 1 || actions.contains { $0.route != .appTrash } }
    var summary: String {
        actions.map(\.title).joined(separator: "；")
    }
}
