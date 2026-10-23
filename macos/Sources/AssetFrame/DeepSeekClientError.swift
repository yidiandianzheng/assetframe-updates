import Foundation

enum DeepSeekClientError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case invalidJSON
    case emptyContent
    case outputLimit
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "DeepSeek API 地址无效"
        case .invalidResponse: "DeepSeek 返回了无法识别的结果"
        case .invalidJSON: "DeepSeek 返回的 JSON 无法识别，已达到重试上限"
        case .outputLimit: "模型输出达到长度上限，未取得完整结果；已保留进度"
        case .emptyContent: "DeepSeek 未返回分析内容，已达到重试上限"
        case .httpStatus(let status, let message):
            if status == 401 || status == 403 { "API 认证失败，请检查现有凭据或服务权限（\(status)）" }
            else if status == 404 { "模型或 API 路径不可用，请检查模型名称及地址" }
            else if status == 429 { "API 请求限流，稍后重试" }
            else if let message, !message.isEmpty { "DeepSeek 请求失败（\(status)：\(message)）" }
            else { "DeepSeek 请求失败（HTTP \(status)）" }
        }
    }
}
