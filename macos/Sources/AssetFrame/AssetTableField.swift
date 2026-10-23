import CoreGraphics
import Foundation

enum AssetTableField: String, CaseIterable, Identifiable, Sendable {
    case image
    case resolution
    case sourceStatus
    case name
    case decision
    case type
    case reuse
    case rating
    case tags
    case master
    case episodes
    case candidatePlan
    case qaResult
    case operation

    var id: Self { self }

    var title: String {
        switch self {
        case .image: "图片"
        case .resolution: "清晰度"
        case .sourceStatus: "源文件"
        case .name: "资产名称"
        case .decision: "审核状态"
        case .type: "资产类型"
        case .reuse: "复用等级"
        case .rating: "评分"
        case .tags: "标签"
        case .master: "通用"
        case .episodes: "所属集数"
        case .candidatePlan: "候选方案"
        case .qaResult: "QA 结果"
        case .operation: "操作"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .resolution: "aspectratio"
        case .sourceStatus: "externaldrive"
        case .name: "textformat"
        case .decision: "checkmark.circle"
        case .type: "square.grid.2x2"
        case .reuse: "arrow.triangle.2.circlepath"
        case .rating: "star"
        case .tags: "tag"
        case .master: "sparkles.rectangle.stack"
        case .episodes: "film.stack"
        case .candidatePlan: "square.stack.3d.up"
        case .qaResult: "checkmark.seal"
        case .operation: "ellipsis"
        }
    }

    func width(imageScale: AssetTableImageScale) -> CGFloat {
        switch self {
        case .image: imageScale.columnWidth
        case .resolution: 104
        case .sourceStatus: 96
        case .name: 260
        case .decision: 124
        case .type: 110
        case .reuse: 86
        case .rating: 112
        case .tags: 176
        case .master: 80
        case .episodes: 126
        case .candidatePlan: 112
        case .qaResult: 112
        case .operation: 58
        }
    }
}
