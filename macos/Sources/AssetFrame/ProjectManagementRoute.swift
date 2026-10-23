import Foundation

enum ProjectManagementRoute: String, Identifiable {
    case create, manage
    var id: String { rawValue }
}
