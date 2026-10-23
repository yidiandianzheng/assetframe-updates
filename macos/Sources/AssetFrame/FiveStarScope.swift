import Foundation

enum FiveStarScope: String, Identifiable, Sendable {
    case currentProject = "当前项目"
    case allProjects = "全部项目"

    var id: String { rawValue }
}
