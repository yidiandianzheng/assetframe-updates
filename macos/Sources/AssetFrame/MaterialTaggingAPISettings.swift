import Foundation
import Security

/// Dedicated external tagging endpoint. Never inherits text/vision settings from other workflows.
enum MaterialTaggingAPISettings {
    struct Draft: Equatable, Sendable {
        var baseURL = ""
        var model = ""
        var apiKey = ""
        var timeout: TimeInterval = 120
        var isComplete: Bool {
            DeepSeekEndpointPolicy.accepts(baseURL: baseURL) && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (10...600).contains(timeout)
        }
    }
    enum Failure: LocalizedError {
        case missing, invalid, unverified, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .missing: "尚未配置标签识别接口，请打开“AI 接口设置”填写你自己的服务地址、模型和 API Key。"
            case .invalid: "请填写有效的服务地址、模型、API Key 和 10–600 秒超时；远程服务须使用 HTTPS。"
            case .unverified: "该接口尚未验证看图能力，请在独立的标签识别接口设置中手动测试。"
            case .keychain(let code): "标签识别接口密钥未能保存或读取（\(code)）。"
            }
        }
    }
    private static let prefix = "assetframe.tagging-api."
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.yidiandian.assetframe") + ".tagging-api" }
    static func hasSavedConfiguration(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.string(forKey: prefix + "url") ?? "").isEmpty && !(defaults.string(forKey: prefix + "model") ?? "").isEmpty
    }
    static func draft(defaults: UserDefaults = .standard, readKey: () -> String? = { readAPIKey() }) -> Draft {
        var value = Draft()
        value.baseURL = defaults.string(forKey: prefix + "url") ?? ""
        value.model = defaults.string(forKey: prefix + "model") ?? ""
        value.timeout = defaults.object(forKey: prefix + "timeout") as? Double ?? 120
        // Opening an unconfigured panel never probes another workflow's keychain entries.
        if hasSavedConfiguration(defaults: defaults) { value.apiKey = readKey() ?? "" }
        return value
    }
    static func checked(mode: String, defaults: UserDefaults = .standard, readKey: () -> String? = { readAPIKey() }) throws -> Draft {
        guard hasSavedConfiguration(defaults: defaults) else { throw Failure.missing }
        let value = draft(defaults: defaults, readKey: readKey)
        guard value.isComplete else { throw Failure.invalid }
        if mode == "看图", !isVisionVerified(value, defaults: defaults) { throw Failure.unverified }
        return value
    }
    static func save(_ input: Draft, defaults: UserDefaults = .standard,
                     writeKey: (String) throws -> Void = { try saveAPIKey($0) }) throws {
        var value = input
        value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.apiKey = value.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isComplete else { throw Failure.invalid }
        try writeKey(value.apiKey)
        defaults.set(value.baseURL, forKey: prefix + "url")
        defaults.set(value.model, forKey: prefix + "model")
        defaults.set(value.timeout, forKey: prefix + "timeout")
        defaults.removeObject(forKey: prefix + "verified")
    }
    private static func verificationKey(_ value: Draft) -> String {
        MaterialTaggingState.digest(Data((value.baseURL + "|" + value.model).utf8))
    }
    static func recordVisionVerification(_ value: Draft, defaults: UserDefaults = .standard) {
        defaults.set(verificationKey(value), forKey: prefix + "verified")
    }
    static func isVisionVerified(_ value: Draft, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: prefix + "verified") == verificationKey(value)
    }
    private static func identity() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
    }
    private static func readAPIKey() -> String? {
        var query = identity()
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(identity() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity(); item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
