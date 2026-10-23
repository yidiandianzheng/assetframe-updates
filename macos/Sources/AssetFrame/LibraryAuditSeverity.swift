import Foundation

enum LibraryAuditSeverity: String, Codable, Sendable {
    case blocking = "阻塞"
    case warning = "提醒"
    case review = "待确认"
}
