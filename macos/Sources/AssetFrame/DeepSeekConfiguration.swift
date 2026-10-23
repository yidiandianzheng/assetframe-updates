import Foundation

struct DeepSeekConfiguration: Sendable {
    var baseURL: String
    var model: String
    var apiKey: String

    var isComplete: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
