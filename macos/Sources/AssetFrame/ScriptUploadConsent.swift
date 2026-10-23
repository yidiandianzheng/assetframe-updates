import Foundation

struct ScriptUploadConsent: Identifiable, Sendable {
    var id: String { fingerprint }
    var url: URL
    var characterCount: Int
    var chunkCount: Int
    var fingerprint: String
    var isDuplicate: Bool
}
