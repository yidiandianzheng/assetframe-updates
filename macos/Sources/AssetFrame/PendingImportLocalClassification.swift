import Foundation

extension PendingImportItem {
    @discardableResult
    mutating func applyLocalClassification(
        _ result: LocalImageClassifier.Result,
        expectedType: AssetType,
        analyzedAt: Date = .now
    ) -> AssetType? {
        localVisionType = result.type
        localVisionLabels = result.labels
        localVisionConfidence = result.confidence
        localVisionAnalyzedAt = analyzedAt

        guard expectedType == .unclassified,
              suggestedType == expectedType,
              let type = result.type,
              let confidence = result.confidence,
              confidence >= LocalImageClassifier.adoptionThreshold else {
            return nil
        }
        suggestedType = type
        return type
    }
}
