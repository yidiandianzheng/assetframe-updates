import Foundation

struct VisionAPIConfiguration: Sendable {
    var baseURL: String
    var model: String
    var apiKey: String
    var timeoutSeconds: Double
    var batchSize: Int

    var isComplete: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        timeoutSeconds >= 10 &&
        (1...8).contains(batchSize)
    }
}
