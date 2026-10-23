import Foundation

@main
struct AssetRemovalPlanSelfTest {
    static func main() {
        let mixed = AssetRemovalPlan(formalIDs: ["A", "B"], pendingIDs: ["P1"])
        precondition(mixed.totalCount == 3)
        precondition(mixed.actions.map(\.route) == [.appTrash, .discardPending])
        precondition(mixed.requiresSummaryConfirmation)
        precondition(mixed.summary.contains("移入回收站 2 项"))
        precondition(mixed.summary.contains("移出待确认 1 项"))

        let quickReview = AssetRemovalPlan(formalIDs: [], pendingIDs: [], quickReviewIDs: ["Q"])
        precondition(quickReview.actions.first?.route == .systemTrashAfterIdentityCheck)
        precondition(quickReview.requiresSummaryConfirmation)

        let formalOnly = AssetRemovalPlan(formalIDs: ["A"], pendingIDs: [])
        precondition(!formalOnly.requiresSummaryConfirmation)

        let targets: Set<AssetActionTarget> = [.formal("A"), .pending("P1"), .quickReview("Q1")]
        let targetPlan = AssetRemovalPlan(targets: targets)
        precondition(targetPlan.actions.map(\.route) == [.appTrash, .discardPending, .systemTrashAfterIdentityCheck])
        precondition(AssetActionTarget.gallery("A") == .formal("A"))
        precondition(AssetActionTarget.gallery("PENDING-P1") == .pending("P1"))
        precondition(AssetActionTarget.pending("P1").capabilities.ratingPromotesToFormal)
        precondition(AssetActionTarget.globalFiveStar("G1").capabilities.removalRoute == nil)
        print("AssetRemovalPlanSelfTest passed")
    }
}
