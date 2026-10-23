import Foundation
import Vision

enum LocalImageClassifier {
    static let adoptionThreshold = 0.42

    struct Result: Equatable, Sendable {
        var type: AssetType?
        var labels: [String]
        var confidence: Double?
        var featurePrintData: Data?
    }

    nonisolated static func classify(atPath path: String, generateFeaturePrint: Bool = false) -> Result {
        guard FileManager.default.fileExists(atPath: path) else {
            return Result(type: nil, labels: [], confidence: nil, featurePrintData: nil)
        }
        return autoreleasepool {
            let classificationRequest = VNClassifyImageRequest()
            let featureRequest = generateFeaturePrint ? VNGenerateImageFeaturePrintRequest() : nil
            let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
            let performed: Bool
            if let featureRequest {
                performed = (try? handler.perform([classificationRequest, featureRequest])) != nil
            } else {
                performed = (try? handler.perform([classificationRequest])) != nil
            }
            guard performed else {
                return Result(type: nil, labels: [], confidence: nil, featurePrintData: nil)
            }

            let observations = classificationRequest.results ?? []
            let labels = observations
                .filter { $0.confidence >= 0.08 }
                .prefix(8)
                .map(\.identifier)
            let prediction = prediction(
                from: observations.prefix(18).map {
                    (identifier: $0.identifier, confidence: Double($0.confidence))
                }
            )
            let featurePrintData = featureRequest?.results?.first.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
            return Result(
                type: prediction?.type,
                labels: labels,
                confidence: prediction?.confidence,
                featurePrintData: featurePrintData
            )
        }
    }

    nonisolated static func prediction(
        from observations: [(identifier: String, confidence: Double)]
    ) -> (type: AssetType, confidence: Double)? {
        let keywords: [(AssetType, [String])] = [
            (.person, ["person", "people", "portrait", "face", "man", "woman", "boy", "girl", "human"]),
            (.creature, ["animal", "mammal", "bird", "reptile", "insect", "fish", "creature"]),
            (.scene, ["building", "architecture", "room", "landscape", "street", "city", "mountain", "outdoor", "indoor", "house", "castle"]),
            (.prop, ["weapon", "tool", "container", "furniture", "device", "accessory", "instrument", "object"])
        ]
        var scores: [AssetType: Double] = [:]
        for observation in observations {
            let label = observation.identifier.lowercased()
            for (type, terms) in keywords where terms.contains(where: label.contains) {
                scores[type, default: 0] += observation.confidence
            }
        }
        guard let best = scores.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, min(1, best.value))
    }
}
