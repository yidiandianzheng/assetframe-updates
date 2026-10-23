import Foundation
import Security
import LocalAuthentication

enum DeepSeekAPISettings {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultFastModel = "deepseek-flash"
    static let defaultDeepModel = "deepseek-flash"

    private static let baseURLKey = "assetframe.deepseek.base-url"
    private static let legacyModelKey = "assetframe.deepseek.model"
    private static let fastModelKey = "assetframe.deepseek.fast-model"
    private static let deepModelKey = "assetframe.deepseek.deep-model"
    private static let keychainService = "com.yidiandian.assetframe.deepseek"
    private static let keychainAccount = "api-key"

    static func draftSettings() -> DeepSeekSettingsDraft {
        let legacyModel = UserDefaults.standard.string(forKey: legacyModelKey)
        return DeepSeekSettingsDraft(
            baseURL: UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL,
            fastModel: UserDefaults.standard.string(forKey: fastModelKey) ?? defaultFastModel,
            deepModel: UserDefaults.standard.string(forKey: deepModelKey) ?? legacyModel ?? defaultDeepModel,
            apiKey: readAPIKey() ?? ""
        )
    }

    static func draftConfiguration(for task: DeepSeekTaskKind) -> DeepSeekConfiguration {
        draftSettings().configuration(for: task)
    }

    static func storedConfiguration(for task: DeepSeekTaskKind) -> DeepSeekConfiguration? {
        let configuration = draftConfiguration(for: task)
        return configuration.isComplete ? configuration : nil
    }

    static var configuredBaseURL: String { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }

    static func checkedConfiguration() throws -> DeepSeekConfiguration {
        let baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
        let fastModel = UserDefaults.standard.string(forKey: fastModelKey) ?? defaultFastModel
        guard !baseURL.isEmpty, !fastModel.isEmpty else { throw DeepSeekSettingsError.configuration("尚未配置 API 地址或快速模型") }
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        // Legacy macOS login-keychain ACLs can ignore LAContext. Background checks
        // must fail without presenting a password sheet; settings remain the explicit entry.
        var interactionWasAllowed = DarwinBoolean(false)
        let interactionStatus = SecKeychainGetUserInteractionAllowed(&interactionWasAllowed)
        guard interactionStatus == errSecSuccess else { throw DeepSeekSettingsError.keychain(interactionStatus) }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { throw DeepSeekSettingsError.keychain(disableStatus) }
        defer { SecKeychainSetUserInteractionAllowed(interactionWasAllowed.boolValue) }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw DeepSeekSettingsError.configuration("尚未保存 API 凭据，请在设置中配置一次") }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw DeepSeekSettingsError.configuration("API 凭据不可读（\(status)）；已保存配置保留，请检查钥匙串权限")
        }
        return DeepSeekConfiguration(baseURL: baseURL, model: fastModel, apiKey: key)
    }

    static func save(_ draft: DeepSeekSettingsDraft) throws {
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fastModel = draft.fastModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let deepModel = draft.deepModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeepSeekEndpointPolicy.accepts(baseURL: baseURL) else {
            throw DeepSeekSettingsError.invalidURL
        }
        guard !fastModel.isEmpty, !deepModel.isEmpty, !apiKey.isEmpty else {
            throw DeepSeekSettingsError.missingFields
        }

        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
        UserDefaults.standard.set(fastModel, forKey: fastModelKey)
        UserDefaults.standard.set(deepModel, forKey: deepModelKey)
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
            guard addStatus == errSecSuccess else { throw DeepSeekSettingsError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw DeepSeekSettingsError.keychain(updateStatus)
        }
    }
}

enum DeepSeekSettingsError: LocalizedError {
    case configuration(String)
    case invalidURL
    case missingFields
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .invalidURL: "API 地址必须使用 HTTPS；仅本机 localhost、127.0.0.1 或 ::1 可使用 HTTP"
        case .missingFields: "请填写 API 地址、模型名称和 API Key"
        case .keychain(let status): "API Key 保存失败（\(status)）"
        }
    }
}
