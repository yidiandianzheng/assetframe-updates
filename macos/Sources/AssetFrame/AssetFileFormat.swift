import Foundation

enum AssetFileFormat {
    static func normalizedExtension(for asset: AssetItem) -> String {
        let candidates = [asset.originalFilename, asset.sourceOriginalPath, asset.imagePath]
        for candidate in candidates.compactMap({ $0 }) where !candidate.isEmpty {
            let value = (candidate as NSString).pathExtension.lowercased()
            if !value.isEmpty { return value }
        }
        return ""
    }
}
