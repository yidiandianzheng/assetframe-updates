import Foundation

enum MaterialTrashService {
    struct Move: Codable, Sendable { var source: String; var destination: String }
    static func paths(for ids: Set<String>, in snapshot: MaterialSnapshot) throws -> [String] {
        let chosen = snapshot.materials.filter { ids.contains($0.id) }
        guard chosen.count == ids.count, !chosen.isEmpty, chosen.allSatisfy({ $0.deletedAt != nil }) else {
            throw MaterialDatabase.error("只允许删除仍在回收站中的素材，请重新选择")
        }
        let paths = Set(chosen.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for material in snapshot.materials where !ids.contains(material.id) {
            if let path = material.sourcePath, paths.contains(URL(fileURLWithPath: path).standardizedFileURL.path) {
                throw MaterialDatabase.error("原文件仍被其他素材记录使用：\(material.name)。请先处理共享记录，原文件未删除")
            }
        }
        for path in paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MaterialDatabase.error("不能删除目录或符号链接：\(path)")
            }
        }
        return paths.sorted()
    }
    static func removing(_ ids: Set<String>, from original: MaterialSnapshot) -> MaterialSnapshot {
        var value = original
        value.materials.removeAll { ids.contains($0.id) }
        value.links.removeAll { ids.contains($0.materialID) }
        for index in value.materials.indices {
            value.materials[index].production?.inputMaterialIDs.removeAll { ids.contains($0) }
            if let parent = value.materials[index].production?.provenance?.parentAssetID, ids.contains(parent) {
                value.materials[index].production?.provenance?.parentAssetID = nil
            }
            if let duplicate = value.materials[index].duplicateContentOf, ids.contains(duplicate) { value.materials[index].duplicateContentOf = nil }
        }
        if var organization = value.organization {
            organization.exportNames = organization.exportNames.filter { !ids.contains($0.key) }
            organization.legacyMapping = organization.legacyMapping.filter { !ids.contains($0.value) }
            value.organization = organization
        }
        return value
    }
}
