import Foundation

struct LibraryAuditSuggestion: Identifiable, Hashable, Sendable {
    var id: String { issueID }
    var issueID: String
    var assetID: String?
    var proposedName: String?
    var assetType: AssetType?
    var tags: [String]
    var summary: String?
    var explanation: String
    var confidence: Double

    var normalizedConfidence: Double { min(1, max(0, confidence)) }
    var hasEditableChange: Bool {
        assetID != nil && (
            proposedName != nil || assetType != nil || !tags.isEmpty || summary != nil
        )
    }
}
