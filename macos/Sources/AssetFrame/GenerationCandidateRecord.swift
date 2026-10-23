import Foundation

struct GenerationCandidateRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var relativePath: String
    var candidateIndex: Int
    var iteration: Int
    var preferredName: String?
    var assetType: AssetType?
    var category: AssetCategory?
    var purpose: AssetPurpose?
    var tags: [String]?
    var sha256: String?
    var generatedAt: Date?
}
