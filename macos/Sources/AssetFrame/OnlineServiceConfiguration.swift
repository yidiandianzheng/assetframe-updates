import Foundation

enum OnlineServiceConfiguration {
    private static let placeholderPrefix = "REPLACE_WITH_"

    static var feedbackEndpoint: URL? {
        configuredHTTPSURL(forInfoKey: "AFFeedbackEndpoint")
    }

    static var sparkleFeedURL: URL? {
        configuredHTTPSURL(forInfoKey: "SUFeedURL")
    }

    static var sparklePublicKey: String? {
        configuredString(forInfoKey: "SUPublicEDKey")
    }

    static var isSparkleConfigured: Bool {
        sparkleFeedURL != nil && sparklePublicKey != nil
    }

    static func configuredString(forInfoKey key: String, bundle: Bundle = .main) -> String? {
        guard let rawValue = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix(placeholderPrefix) else { return nil }
        return value
    }

    static func isAllowedServiceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func configuredHTTPSURL(forInfoKey key: String, bundle: Bundle = .main) -> URL? {
        guard let value = configuredString(forInfoKey: key, bundle: bundle),
              let url = URL(string: value),
              isAllowedServiceURL(url) else { return nil }
        return url
    }
}
