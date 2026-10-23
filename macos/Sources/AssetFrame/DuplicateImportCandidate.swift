import Foundation

enum DuplicateImportDecision: String, CaseIterable, Identifiable, Sendable {
    case useExisting = "使用现有文件"
    case keepBoth = "保留两者"

    var id: String { rawValue }
}

struct DuplicateImportCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var existingPath: String
    var incomingItem: PendingImportItem

    init(id: UUID = UUID(), existingPath: String, incomingItem: PendingImportItem) {
        self.id = id
        self.existingPath = existingPath
        self.incomingItem = incomingItem
    }

    var incomingPath: String { incomingItem.originalSourcePath }
    var existingFilename: String { URL(fileURLWithPath: existingPath).lastPathComponent }
    var incomingFilename: String { incomingItem.originalFilename }
    var dimensionText: String { incomingItem.dimensionText }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: incomingItem.sourceFileSize, countStyle: .file)
    }

    var queueIdentity: String {
        "\(URL(fileURLWithPath: existingPath).standardizedFileURL.path)|\(incomingItem.sourceIdentity)"
    }

    var incomingPreviewAsset: AssetItem { incomingItem.makePreviewAsset(checkSourceAvailability: false) }

    var existingPreviewAsset: AssetItem {
        var asset = incomingPreviewAsset
        asset.id = "DUPLICATE-EXISTING-\(id.uuidString)"
        asset.imagePath = existingPath
        asset.originalFilename = existingFilename
        return asset
    }
}
