import Foundation

enum DeepSeekEndpointPolicy {
    static func accepts(baseURL: String) -> Bool {
        validatedComponents(from: baseURL) != nil
    }

    static func chatCompletionsURL(from baseURL: String) -> URL? {
        guard var components = validatedComponents(from: baseURL) else { return nil }
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !normalizedPath.hasSuffix("chat/completions") {
            components.path = "/" + [normalizedPath, "chat/completions"]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }
        return components.url
    }

    private static func validatedComponents(from baseURL: String) -> URLComponents? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }

        let usesEncryptedTransport = scheme == "https"
        let usesLocalLoopback = scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        guard usesEncryptedTransport || usesLocalLoopback else { return nil }

        components.scheme = scheme
        return components
    }
}
