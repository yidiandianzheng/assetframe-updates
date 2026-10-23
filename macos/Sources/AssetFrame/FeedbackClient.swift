import Foundation

protocol FeedbackSending: Sendable {
    func submit(_ submission: FeedbackSubmissionV1, screenshot: Data?) async throws -> FeedbackServerResponse
}

struct URLSessionFeedbackClient: FeedbackSending {
    let endpoint: URL
    var session: URLSession = .shared

    func submit(_ submission: FeedbackSubmissionV1, screenshot: Data?) async throws -> FeedbackServerResponse {
        try submission.validate(screenshotBytes: screenshot?.count)
        guard OnlineServiceConfiguration.isAllowedServiceURL(endpoint) else {
            throw FeedbackClientError.insecureEndpoint
        }

        let boundary = "AssetFrame-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("AssetFrame/\(AppVersion.build)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try FeedbackMultipartBody.make(
            submission: submission,
            screenshot: screenshot,
            boundary: boundary
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw FeedbackClientError.invalidResponse }
        guard [200, 202].contains(httpResponse.statusCode) else {
            let serverMessage = String(data: data.prefix(1_024), encoding: .utf8)
            throw FeedbackClientError.server(statusCode: httpResponse.statusCode, message: serverMessage)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
            }
            return date
        }
        do {
            return try decoder.decode(FeedbackServerResponse.self, from: data)
        } catch {
            throw FeedbackClientError.invalidResponse
        }
    }
}

enum FeedbackMultipartBody {
    static func make(
        submission: FeedbackSubmissionV1,
        screenshot: Data?,
        boundary: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(submission)
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"payload\"\r\n")
        body.appendUTF8("Content-Type: application/json; charset=utf-8\r\n\r\n")
        body.append(payload)
        body.appendUTF8("\r\n")

        if let screenshot {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"screenshot\"; filename=\"feedback.jpg\"\r\n")
            body.appendUTF8("Content-Type: image/jpeg\r\n\r\n")
            body.append(screenshot)
            body.appendUTF8("\r\n")
        }

        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }
}

enum FeedbackClientError: LocalizedError {
    case insecureEndpoint
    case invalidResponse
    case server(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint:
            "反馈服务器必须使用 HTTPS；只有本机调试地址允许 HTTP。"
        case .invalidResponse:
            "反馈服务器返回了无法识别的结果。"
        case .server(let statusCode, _):
            statusCode == 429 ? "提交过于频繁，请稍后再试。" : "反馈服务器暂时不可用（HTTP \(statusCode)）。"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
