import AppKit
import Foundation

struct AssetDragPayload: Codable, Sendable {
    var projectID: String
    var assetID: String
    var assetIDs: [String]? = nil

    var allAssetIDs: [String] {
        var seen = Set<String>()
        return (assetIDs ?? [assetID]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum AssetDragPasteboard {
    static let identifier = "com.vector-time.assetframe.asset-id"
    static let type = NSPasteboard.PasteboardType(identifier)
}
