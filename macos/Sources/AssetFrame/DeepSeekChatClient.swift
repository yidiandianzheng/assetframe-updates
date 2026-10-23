import Foundation

private actor DeepSeekRequestGate {
    static let shared = DeepSeekRequestGate()
    private var occupied = false
    func acquire() async throws {
        while occupied { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation(); occupied = true
    }
    func release() { occupied = false }
}

enum DeepSeekChatClient {
    private struct ChatMessage: Codable, Sendable {
        var role: String
        var content: String
    }

    private struct ChatRequest: Encodable, Sendable {
        var model: String
        var messages: [ChatMessage]
        var responseFormat: [String: String]
        var maxTokens: Int
        var thinking: [String: String]?
        var stream = false

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, thinking
            case responseFormat = "response_format"
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponse: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            var message: ChatMessage
            var finish_reason: String?
        }

        var choices: [Choice]
    }

    static func requestJSON<Value: Sendable>(
        configuration: DeepSeekConfiguration,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        disableThinking: Bool = false,
        decode: @escaping @Sendable (String) throws -> Value
    ) async throws -> Value {
        try await DeepSeekRequestGate.shared.acquire()
        defer { Task { await DeepSeekRequestGate.shared.release() } }
        var lastError: Error = DeepSeekClientError.invalidResponse
        for attempt in 0...2 {
            try Task.checkCancellation()
            do {
                let content = try await request(
                    configuration: configuration,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: maxTokens,
                    disableThinking: disableThinking
                )
                do {
                    return try decode(content)
                } catch {
                    throw DeepSeekClientError.invalidJSON
                }
            } catch {
                lastError = error
                guard attempt < 2, isRetryable(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 5))
            }
        }
        throw lastError
    }

    private static func request(
        configuration: DeepSeekConfiguration,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        disableThinking: Bool
    ) async throws -> String {
        let body = ChatRequest(
            model: configuration.model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt)
            ],
            responseFormat: ["type": "json_object"],
            maxTokens: maxTokens,
            thinking: disableThinking ? ["type": "disabled"] : nil
        )

        guard let endpointURL = DeepSeekEndpointPolicy.chatCompletionsURL(from: configuration.baseURL) else {
            throw DeepSeekClientError.invalidEndpoint
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepSeekClientError.httpStatus(httpResponse.statusCode, serverMessage(from: data))
        }
        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        if chat.choices.first?.finish_reason == "length" { throw DeepSeekClientError.outputLimit }
        guard let content = chat.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekClientError.emptyContent
        }
        return content
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? URLError { return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) }
        guard let error = error as? DeepSeekClientError else { return false }
        if case .httpStatus(let code, _) = error { return code == 429 || (500...599).contains(code) }
        return error == .emptyContent || error == .invalidJSON
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
