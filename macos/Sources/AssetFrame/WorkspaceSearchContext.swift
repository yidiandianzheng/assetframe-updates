import Foundation

enum WorkspaceSearchContext: String, CaseIterable, Equatable {
    case assets
    case globalFiveStar
    case materials
    case unsupported

    var supportsSearch: Bool { self != .unsupported }
}
