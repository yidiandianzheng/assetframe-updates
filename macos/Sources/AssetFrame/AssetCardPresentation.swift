import CoreGraphics
import Foundation

struct AssetCardPresentation: Equatable, Sendable {
    var showsName: Bool
    var showsDescription: Bool = false
    var showsSecondaryInfo: Bool
    var secondaryInfoMode: AssetSecondaryInfoMode
    var showsExtension: Bool
    var showsTags: Bool
    var showsTagCount: Bool = false
    var showsRating: Bool

    var showsSecondaryLine: Bool { showsDescription || showsSecondaryInfo || showsTags || showsTagCount || showsRating }

    var footerLineCount: Int {
        (showsName ? 1 : 0) + (showsSecondaryLine ? 1 : 0)
    }

    var footerHeight: CGFloat {
        switch footerLineCount {
        case 0: 0
        case 1: 22
        default: 40
        }
    }

    func displayName(for asset: AssetItem) -> String? {
        guard showsName else { return nil }
        if showsExtension { return asset.originalFilename }
        let value = (asset.originalFilename as NSString).deletingPathExtension
        return value.isEmpty ? asset.name : value
    }

    func secondaryText(for asset: AssetItem) -> String? {
        var parts: [String] = []
        if showsDescription {
            let description = asset.assetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = asset.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty {
                parts.append(description)
            } else if !note.isEmpty {
                parts.append(note)
            }
        }
        if showsSecondaryInfo {
            switch secondaryInfoMode {
            case .dimensionsAndSize:
                parts.append(asset.dimensionText)
                parts.append(fileSizeText(for: asset))
            case .dimensions:
                parts.append(asset.dimensionText)
            case .fileSize:
                parts.append(fileSizeText(for: asset))
            }
        }
        if showsRating, asset.starRating > 0 {
            parts.append("\(asset.starRating)★")
        }
        if !asset.normalizedTags.isEmpty {
            if showsTags {
                let visibleTags = asset.normalizedTags.prefix(2).joined(separator: " · ")
                let remaining = asset.normalizedTags.count - min(asset.normalizedTags.count, 2)
                parts.append(showsTagCount && remaining > 0 ? "\(visibleTags) +\(remaining)" : visibleTags)
            } else if showsTagCount {
                parts.append("\(asset.normalizedTags.count) 个标签")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "　")
    }

    var cacheKey: String {
        [
            showsName ? "name" : "noname",
            showsDescription ? "description" : "nodescription",
            showsSecondaryInfo ? "info" : "noinfo",
            secondaryInfoMode.rawValue,
            showsExtension ? "ext" : "noext",
            showsTags ? "tags" : "notags",
            showsTagCount ? "tagcount" : "notagcount",
            showsRating ? "rating" : "norating"
        ].joined(separator: "|")
    }

    private func fileSizeText(for asset: AssetItem) -> String {
        guard let fileSize = asset.sourceFileSize, fileSize >= 0 else { return "大小待识别" }
        return fileSize.formatted(.byteCount(style: .file))
    }
}
