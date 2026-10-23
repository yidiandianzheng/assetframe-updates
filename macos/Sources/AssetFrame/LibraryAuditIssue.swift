import Foundation

struct LibraryAuditIssue: Identifiable, Hashable, Sendable {
    var id: String
    var kind: LibraryAuditIssueKind
    var severity: LibraryAuditSeverity
    var title: String
    var detail: String
    var assetIDs: [String]
    var variantID: String?
}
