import Foundation

struct AssetInspectorMetadata: Equatable, Sendable {
    let dimensionText: String
    let fileSizeText: String
    let formatText: String
    let createdAtText: String
    let sourceCreatedAtText: String
    let modifiedAtText: String

    init(asset: AssetItem, filePath: String?) {
        dimensionText = asset.dimensionText
        if let size = asset.sourceFileSize, size >= 0 {
            fileSizeText = size.formatted(.byteCount(style: .file))
        } else {
            fileSizeText = "待识别"
        }

        let candidates = [filePath, asset.originalFilename, asset.imagePath]
        let fileExtension = candidates
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        formatText = fileExtension?.uppercased() ?? "待识别"
        createdAtText = Self.format(asset.createdAt)
        sourceCreatedAtText = asset.sourceCreatedAt.map(Self.format) ?? "待识别"
        modifiedAtText = asset.sourceModifiedAt.map(Self.format) ?? "待识别"
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
