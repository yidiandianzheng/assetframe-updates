import Foundation
import Security

enum VisionAPISettings {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = ""
    static let defaultTimeoutSeconds = 120.0
    static let defaultBatchSize = 2

    private static let baseURLKey = "assetframe.vision-api.base-url"
    private static let modelKey = "assetframe.vision-api.model"
    private static let timeoutKey = "assetframe.vision-api.timeout-seconds"
    private static let batchSizeKey = "assetframe.vision-api.batch-size"
    private static let keychainService = "com.yidiandian.assetframe.vision-api"
    private static let keychainAccount = "api-key"

    static func draftConfiguration(defaults: UserDefaults = .standard) -> VisionAPIConfiguration {
        let storedTimeout = defaults.double(forKey: timeoutKey)
        let storedBatchSize = defaults.integer(forKey: batchSizeKey)
        return VisionAPIConfiguration(
            baseURL: defaults.string(forKey: baseURLKey) ?? defaultBaseURL,
            model: defaults.string(forKey: modelKey) ?? defaultModel,
            apiKey: readAPIKey() ?? "",
            timeoutSeconds: storedTimeout > 0 ? storedTimeout : defaultTimeoutSeconds,
            batchSize: storedBatchSize > 0 ? storedBatchSize : defaultBatchSize
        )
    }

    static func storedConfiguration(defaults: UserDefaults = .standard) -> VisionAPIConfiguration? {
        let configuration = draftConfiguration(defaults: defaults)
        return configuration.isComplete ? configuration : nil
    }

    static func save(_ configuration: VisionAPIConfiguration) throws {
        let baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeepSeekEndpointPolicy.accepts(baseURL: baseURL) else {
            throw VisionAPISettingsError.invalidURL
        }
        guard !model.isEmpty, !apiKey.isEmpty else {
            throw VisionAPISettingsError.missingFields
        }
        guard configuration.timeoutSeconds >= 10, configuration.timeoutSeconds <= 600 else {
            throw VisionAPISettingsError.invalidTimeout
        }
        guard (1...8).contains(configuration.batchSize) else {
            throw VisionAPISettingsError.invalidBatchSize
        }

        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
        UserDefaults.standard.set(model, forKey: modelKey)
        UserDefaults.standard.set(configuration.timeoutSeconds, forKey: timeoutKey)
        UserDefaults.standard.set(configuration.batchSize, forKey: batchSizeKey)
        try saveAPIKey(apiKey)
    }

    private static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveAPIKey(_ apiKey: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let data = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw VisionAPISettingsError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw VisionAPISettingsError.keychain(updateStatus)
        }
    }
}

enum VisionAPISettingsError: LocalizedError {
    case invalidURL
    case missingFields
    case invalidTimeout
    case invalidBatchSize
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "API 地址必须使用 HTTPS；仅 localhost、127.0.0.1 或 ::1 可使用 HTTP"
        case .missingFields: "请填写视觉 API 地址、模型名称和 API Key"
        case .invalidTimeout: "超时时间必须在 10–600 秒之间"
        case .invalidBatchSize: "并发数量必须在 1–8 之间"
        case .keychain(let status): "视觉 API Key 保存失败（\(status)）"
        }
    }
}
