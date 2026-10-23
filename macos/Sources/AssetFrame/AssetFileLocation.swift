import Foundation

/// 一个资产记录只暴露一个当前有效文件位置。
struct AssetFileLocation: Identifiable, Hashable, Sendable {
    let path: String
    let exists: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

enum AssetFileLocationResolver {
    static func location(path: String?, fileManager: FileManager = .default) -> AssetFileLocation? {
        guard let path = cleanedPath(path) else { return nil }
        return AssetFileLocation(path: path, exists: fileManager.fileExists(atPath: path))
    }

    static func location(for asset: AssetItem, fileManager: FileManager = .default) -> AssetFileLocation? {
        location(path: asset.imagePath, fileManager: fileManager)
    }

    /// 旧版全局素材可能保存过多个来源。优先迁移到仍存在的路径，否则保留原主路径供用户重新定位。
    static func canonicalMaterialPath(for material: MaterialRecord, fileManager: FileManager = .default) -> String? {
        canonicalMaterialPath(primary: material.sourcePath, alternatives: material.sourceLocations, fileManager: fileManager)
    }

    static func canonicalMaterialPath(primary: String?, alternatives: [String], fileManager: FileManager = .default) -> String? {
        let candidates = ([primary].compactMap { $0 } + alternatives)
            .filter { !$0.contains("://") }
            .compactMap(cleanedPath)
        guard !candidates.isEmpty else { return nil }
        return candidates.first(where: { fileManager.fileExists(atPath: $0) }) ?? candidates[0]
    }

    static func location(for material: MaterialRecord, fileManager: FileManager = .default) -> AssetFileLocation? {
        location(path: canonicalMaterialPath(for: material, fileManager: fileManager), fileManager: fileManager)
    }

    private static func cleanedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

extension MaterialRecord {
    var fileLocation: AssetFileLocation? { AssetFileLocationResolver.location(for: self) }
}
