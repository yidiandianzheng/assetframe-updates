import Foundation

struct GenerationProvenance: Codable, Hashable, Sendable {
    var batchID: String
    var candidateID: String
    var taskID: String?
    var taskTitle: String
    var generationPlatform: String
    var modelName: String?
    var operation: GenerationOperation
    var candidateIndex: Int
    var iteration: Int
    var contentSHA256: String
    var parentBatchID: String?
    var parentAssetID: String?
    var parentFingerprint: String?
    var generatedAt: Date
    var manifestRelativePath: String

    var candidateLabel: String {
        "R\(iteration.formatted(.number.precision(.integerLength(2)))) · C\(candidateIndex.formatted(.number.precision(.integerLength(2))))"
    }
}
