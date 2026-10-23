import Foundation

@main
enum ContextualInspectorStateSelfTest {
    static func main() {
        let scope = InspectorScopeSummary(
            title: "已链接文件夹",
            itemCount: 3,
            totalFileSize: 600,
            missingSourceCount: 1,
            queryIsActive: false
        )
        let records = [
            InspectorSelectionRecord(id: "A", kind: .formal, fileSize: 100, sourceMissing: false),
            InspectorSelectionRecord(id: "B", kind: .formal, fileSize: 200, sourceMissing: true),
            InspectorSelectionRecord(id: "PENDING-C", kind: .pending, fileSize: 300, sourceMissing: false),
            InspectorSelectionRecord(id: "G", kind: .globalFiveStar, fileSize: 400, sourceMissing: false),
            InspectorSelectionRecord(id: "M", kind: .material, fileSize: 500, sourceMissing: false)
        ]

        precondition(ContextualInspectorResolver.resolve(selectedIDs: [], records: records, scope: scope) == .scope(scope))
        precondition(ContextualInspectorResolver.resolve(selectedIDs: ["missing"], records: records, scope: scope) == .scope(scope))
        precondition(ContextualInspectorResolver.resolve(selectedIDs: ["A"], records: records, scope: scope) == .singleFormal("A"))
        precondition(ContextualInspectorResolver.resolve(selectedIDs: ["PENDING-C"], records: records, scope: scope) == .singlePending("PENDING-C"))
        precondition(ContextualInspectorResolver.resolve(selectedIDs: ["G"], records: records, scope: scope) == .singleGlobalFiveStar("G"))
        precondition(ContextualInspectorResolver.resolve(selectedIDs: ["M"], records: records, scope: scope) == .singleMaterial("M"))

        let mixed = ContextualInspectorResolver.resolve(
            selectedIDs: ["A", "B", "PENDING-C", "missing"],
            records: records,
            scope: scope
        )
        guard case .multiple(let summary) = mixed else { preconditionFailure("混合选择应进入批量检查器") }
        precondition(summary.formalIDs == ["A", "B"])
        precondition(summary.pendingIDs == ["PENDING-C"])
        precondition(summary.itemCount == 3)
        precondition(summary.totalFileSize == 600)
        precondition(summary.missingSourceCount == 1)

        let aggregate = ContextualInspectorResolver.resolve(
            selectedIDs: ["G", "M"],
            records: records,
            scope: scope
        )
        guard case .multiple(let aggregateSummary) = aggregate else { preconditionFailure("聚合选择应进入批量检查器") }
        precondition(aggregateSummary.globalFiveStarIDs == ["G"])
        precondition(aggregateSummary.materialIDs == ["M"])

        print("Contextual inspector state self-test passed")
    }
}
