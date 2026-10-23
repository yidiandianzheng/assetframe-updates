import Foundation

struct GlobalFiveStarSource: Identifiable, Hashable, Sendable {
    var projectID: String
    var projectName: String
    var assetID: String
    var asset: AssetItem

    var id: String { "\(projectID):\(assetID)" }
}
