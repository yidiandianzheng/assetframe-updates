import Foundation

enum GenerationOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case create
    case edit
    case regenerate
    case upscale

    var id: Self { self }

    var displayName: String {
        switch self {
        case .create: "原生生成"
        case .edit: "改图"
        case .regenerate: "重生成"
        case .upscale: "超分"
        }
    }
}
