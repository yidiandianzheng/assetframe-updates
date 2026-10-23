import Foundation

struct LibraryAuditSession: Identifiable, Sendable {
    enum Phase: Sendable {
        case localReady
        case analyzing
        case completed
        case failed
    }

    let id: UUID
    let projectID: String
    let scopeDescription: String
    var issues: [LibraryAuditIssue]
    var suggestions: [LibraryAuditSuggestion]
    var appliedSuggestionIDs: Set<String>
    var phase: Phase
    var message: String

    var isAnalyzing: Bool { phase == .analyzing }
}
