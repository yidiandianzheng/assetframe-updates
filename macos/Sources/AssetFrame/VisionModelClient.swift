import Foundation

struct VisionAnalysisInput: Sendable {
    var itemID: String
    var imagePath: String
    var filename: String
    var relativePath: String?
    var currentType: AssetType
    var localVisionLabels: [String]
}

protocol VisionModelClient: Sendable {
    func analyze(
        input: VisionAnalysisInput,
        configuration: VisionAPIConfiguration
    ) async throws -> PendingAIAnalysisSuggestion

    func testConnection(configuration: VisionAPIConfiguration) async throws
}
