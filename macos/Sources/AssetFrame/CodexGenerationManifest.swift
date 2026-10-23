import Foundation

struct CodexGenerationManifest: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var projectID: String
    var batchID: String
    var taskID: String?
    var taskTitle: String
    var generationPlatform: String
    var modelName: String?
    var prompt: String
    var promptHash: String?
    var operation: GenerationOperation
    var parentBatchID: String?
    var parentAssetID: String?
    var parentFingerprint: String?
    var intendedType: AssetType?
    var entityName: String?
    var variantName: String?
    var createdAt: Date
    var candidates: [GenerationCandidateRecord]
}
