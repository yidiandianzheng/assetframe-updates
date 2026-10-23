import Foundation

enum VisionAPIClientError: LocalizedError, Equatable {
    case invalidEndpoint
    case unreadableImage
    case imageEncodingFailed
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyContent
    case invalidJSON
    case mismatchedItem
    case visionTestFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "视觉 API 地址无效"
        case .unreadableImage: "无法读取这张图片"
        case .imageEncodingFailed: "无法生成用于分析的 1280px 预览图"
        case .invalidResponse: "视觉 API 返回了无法识别的响应"
        case .httpStatus(let code, let message):
            message.map { "视觉 API 请求失败（HTTP \(code)）：\($0)" } ?? "视觉 API 请求失败（HTTP \(code)）"
        case .emptyContent: "视觉模型没有返回分析内容"
        case .invalidJSON: "视觉模型没有按要求返回 JSON"
        case .mismatchedItem: "视觉模型返回了不匹配的图片编号"
        case .visionTestFailed: "模型未能识别测试图的红蓝区域，无法确认它具备看图能力"
        }
    }
}
