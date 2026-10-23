import Foundation

struct CodexGenerationProjectContext: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var projectID: String
    var projectName: String
    var projectRootPath: String
    var inboxPath: String
    var inboxRelativePath: String
    var manifestFilename: String
    var namingPattern: String
    var updatedAt: Date
}
