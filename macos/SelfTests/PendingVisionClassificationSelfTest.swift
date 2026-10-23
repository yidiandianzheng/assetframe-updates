import Foundation

@main
struct PendingVisionClassificationSelfTest {
    static func main() throws {
        let personPrediction = LocalImageClassifier.prediction(from: [
            (identifier: "portrait, person", confidence: 0.61),
            (identifier: "human face", confidence: 0.18)
        ])
        precondition(personPrediction?.type == .person)
        precondition((personPrediction?.confidence ?? 0) >= 0.79)

        let scenePrediction = LocalImageClassifier.prediction(from: [
            (identifier: "castle, architecture", confidence: 0.55)
        ])
        precondition(scenePrediction?.type == .scene)

        var pending = makeItem()
        let accepted = pending.applyLocalClassification(
            .init(type: .prop, labels: ["weapon", "tool"], confidence: 0.72, featurePrintData: nil),
            expectedType: .unclassified
        )
        precondition(accepted == .prop)
        precondition(pending.suggestedType == .prop)
        precondition(pending.localVisionType == .prop)
        precondition(pending.localVisionAnalyzedAt != nil)

        var manuallyEdited = makeItem()
        let expectedType = manuallyEdited.suggestedType
        manuallyEdited.suggestedType = .scene
        let overwritten = manuallyEdited.applyLocalClassification(
            .init(type: .person, labels: ["person"], confidence: 0.95, featurePrintData: nil),
            expectedType: expectedType
        )
        precondition(overwritten == nil)
        precondition(manuallyEdited.suggestedType == .scene)
        precondition(manuallyEdited.localVisionType == .person)

        var lowConfidence = makeItem()
        let lowResult = lowConfidence.applyLocalClassification(
            .init(type: .person, labels: ["person"], confidence: 0.2, featurePrintData: nil),
            expectedType: .unclassified
        )
        precondition(lowResult == nil)
        precondition(lowConfidence.suggestedType == .unclassified)
        precondition(lowConfidence.localVisionAnalyzedAt != nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(makeItem())
        guard var legacyObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            fatalError("PendingImportItem JSON should be an object")
        }
        legacyObject.removeValue(forKey: "localVisionType")
        legacyObject.removeValue(forKey: "localVisionLabels")
        legacyObject.removeValue(forKey: "localVisionConfidence")
        legacyObject.removeValue(forKey: "localVisionAnalyzedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PendingImportItem.self, from: legacyData)
        precondition(restored.localVisionAnalyzedAt == nil)
        precondition(restored.suggestedType == .unclassified)

        print("PendingVisionClassificationSelfTest passed")
    }

    private static func makeItem() -> PendingImportItem {
        PendingImportItem(
            id: "P1",
            stagedPath: "/tmp/pending.png",
            originalSourcePath: "/tmp/source.png",
            originalFilename: "未命名.png",
            sourceFileID: "F1",
            sourceFileSize: 12,
            sourceModifiedAt: .distantPast,
            pixelWidth: 1024,
            pixelHeight: 1024,
            suggestedType: .unclassified,
            category: .pending,
            createdAt: .distantPast
        )
    }
}
