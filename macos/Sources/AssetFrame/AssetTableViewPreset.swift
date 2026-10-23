import Foundation

enum AssetTableViewPreset: String, CaseIterable, Identifiable, Sendable {
    case all = "资产总表"
    case review = "审核确认"
    case production = "生产跟踪"
    case quality = "文件质量"

    var id: Self { self }

    var subtitle: String {
        switch self {
        case .all: "查看资产的完整字段"
        case .review: "集中确认状态、类型、等级和精选母版"
        case .production: "跟踪集数、候选方案和 QA 结果"
        case .quality: "检查原图、分辨率和验收结果"
        }
    }

    var fields: [AssetTableField] {
        switch self {
        case .all:
            [.image, .resolution, .name, .decision, .type, .reuse, .rating, .tags, .master, .episodes, .candidatePlan, .qaResult, .operation]
        case .review:
            [.image, .name, .decision, .type, .reuse, .rating, .master, .operation]
        case .production:
            [.image, .name, .type, .reuse, .episodes, .candidatePlan, .qaResult, .operation]
        case .quality:
            [.image, .resolution, .sourceStatus, .name, .type, .qaResult, .operation]
        }
    }

    var defaultGroup: AssetTableGroupOption {
        switch self {
        case .all: .none
        case .review: .decision
        case .production: .type
        case .quality: .sourceStatus
        }
    }
}
