import Foundation

struct DeepSeekSettingsDraft: Sendable {
    var baseURL: String
    var fastModel: String
    var deepModel: String
    var apiKey: String

    func configuration(for task: DeepSeekTaskKind) -> DeepSeekConfiguration {
        DeepSeekConfiguration(
            baseURL: baseURL,
            model: task.usesDeepModel ? deepModel : fastModel,
            apiKey: apiKey
        )
    }
}
