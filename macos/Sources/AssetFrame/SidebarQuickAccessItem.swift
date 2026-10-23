import Foundation

struct SidebarQuickAccessItem: Identifiable, Codable, Hashable, Sendable {
    var projectID: String
    var sourceID: String
    var relativePath: String

    var id: String {
        "\(projectID)|\(sourceID)|\(relativePath)"
    }

    var displayName: String {
        relativePath.isEmpty ? "资料库根目录" : (relativePath as NSString).lastPathComponent
    }
}

