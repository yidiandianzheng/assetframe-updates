import Foundation

enum ProjectLoadStage: Equatable, Sendable {
    case idle
    case preparing
    case loadingDatabase
    case buildingIndex
    case renderingFirstScreen
    case ready
    case failed

    var statusText: String {
        switch self {
        case .idle, .preparing: "正在准备项目"
        case .loadingDatabase: "正在读取素材"
        case .buildingIndex: "正在建立索引"
        case .renderingFirstScreen: "正在显示首屏"
        case .ready: "项目已就绪"
        case .failed: "项目读取失败"
        }
    }
}

struct ProjectLoadProgress: Equatable, Sendable {
    let projectID: String
    let projectName: String
    var stage: ProjectLoadStage
    var completed: Int
    var total: Int?
    let startedAt: Date

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct ProjectDatabaseLoadProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
}
