import Foundation

/// 库级分类配置；只引用已入库素材，不修改素材上的旧全局分类。
struct ProjectClassificationProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var roots: [String]
    var sources: [ProjectClassificationSource] = []
    var dimensions: [ProjectClassificationDimension] = []
    var selected: [String: Set<String>] = [:]
    var expanded: Bool = true
    var issue: String? = nil

    var orderedDimensions: [ProjectClassificationDimension] {
        dimensions.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            // 置顶和人工顺序覆盖索引优先级；缺省仍沿用源文次序。
            if $0.manualOrder != $1.manualOrder { return ($0.manualOrder ?? Int.max) < ($1.manualOrder ?? Int.max) }
            if $0.priority != $1.priority { return ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }

    func memberIDs(materials: [MaterialRecord]) -> Set<String> {
        Set(memberPaths(materials: materials).keys)
    }

    func matchingIDs(materials: [MaterialRecord], ignoringDimension: String? = nil) -> Set<String> {
        if let ignoringDimension {
            var without = self
            without.selected.removeValue(forKey: ignoringDimension)
            return without.evaluation(materials: materials).matchingIDs
        }
        return evaluation(materials: materials).matchingIDs
    }

    func optionCount(_ option: ProjectClassificationOption, dimensionID: String, materials: [MaterialRecord]) -> Int {
        evaluation(materials: materials).counts[dimensionID]?[option.id] ?? 0
    }

    /// 单次查询共用一次路径规范化、项目范围与选项集合，供界面同时取得结果和全部胶囊计数。
    func evaluation(materials: [MaterialRecord]) -> (matchingIDs: Set<String>, counts: [String: [String: Int]]) {
        let pathsByID = memberPaths(materials: materials)
        let members = Set(pathsByID.keys)
        var optionIDs: [String: [String: Set<String>]] = [:]
        for dimension in dimensions where optionIDs[dimension.id] == nil {
            var direct: [String: Set<String>] = [:]
            for option in dimension.options where direct[option.id] == nil {
                var ids = option.unavailable ? Set<String>() : option.materialIDs
                ids.formUnion(option.manualMaterialIDs)
                for rawPath in option.manualPaths {
                    guard ProjectClassificationParser.isSafePath(rawPath, roots: roots) else { continue }
                    let normalized = ProjectClassificationParser.canonical(rawPath)
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: normalized, isDirectory: &directory) else { continue }
                    for (id, paths) in pathsByID where paths.contains(where: {
                        directory.boolValue ? ProjectClassificationParser.path($0, isInside: normalized) : $0 == normalized
                    }) { ids.insert(id) }
                }
                direct[option.id] = ids.intersection(members)
            }
            var resolved: [String: Set<String>] = [:]
            let options = Dictionary(dimension.options.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for option in dimension.options {
                var pending = [option.id]
                var visited = Set<String>()
                var ids = Set<String>()
                while let id = pending.popLast() {
                    guard visited.insert(id).inserted else { continue }
                    ids.formUnion(direct[id] ?? [])
                    pending.append(contentsOf: options[id]?.mergedIDs ?? [])
                }
                resolved[option.id] = ids
            }
            optionIDs[dimension.id] = resolved
        }
        var chosenIDs: [String: Set<String>] = [:]
        for (dimensionID, chosen) in selected where !chosen.isEmpty {
            // 未知维度或未知选项贡献空集合，不能把过期条件误当成“不限”。
            chosenIDs[dimensionID] = chosen.reduce(into: Set<String>()) {
                $0.formUnion(optionIDs[dimensionID]?[$1] ?? [])
            }
        }
        var matches = members
        for ids in chosenIDs.values { matches.formIntersection(ids) }
        var counts: [String: [String: Int]] = [:]
        for (dimensionID, options) in optionIDs {
            var others = members
            for (chosenDimension, ids) in chosenIDs where chosenDimension != dimensionID { others.formIntersection(ids) }
            counts[dimensionID] = options.mapValues { $0.intersection(others).count }
        }
        return (matches, counts)
    }

    private func memberPaths(materials: [MaterialRecord]) -> [String: Set<String>] {
        let normalizedRoots = roots.map(ProjectClassificationParser.canonical)
        var normalizedPaths: [String: String] = [:]
        var result: [String: Set<String>] = [:]
        for material in materials where material.deletedAt == nil {
            for rawPath in ([material.sourcePath].compactMap { $0 } + material.sourceLocations) where !rawPath.isEmpty {
                let normalized: String
                if let cached = normalizedPaths[rawPath] { normalized = cached }
                else {
                    normalized = ProjectClassificationParser.canonical(rawPath)
                    normalizedPaths[rawPath] = normalized
                }
                if normalizedRoots.contains(where: { ProjectClassificationParser.path(normalized, isInside: $0) }) {
                    result[material.id, default: []].insert(normalized)
                }
            }
        }
        return result
    }

}

struct ProjectClassificationSource: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }
    var path: String
    var fingerprint: String
}

struct ProjectClassificationEvidence: Codable, Hashable, Sendable {
    var path: String
    var line: Int
    var text: String
}

struct ProjectClassificationDimension: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sourceName: String
    var displayName: String
    var order: Int = 0
    var priority: Int? = nil
    var manualOrder: Int? = nil
    var pinned: Bool = false
    var options: [ProjectClassificationOption] = []
    var name: String { displayName.isEmpty ? sourceName : displayName }
    var orderedOptions: [ProjectClassificationOption] {
        options.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.manualOrder != $1.manualOrder { return ($0.manualOrder ?? Int.max) < ($1.manualOrder ?? Int.max) }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }
}

struct ProjectClassificationOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sourceName: String
    var displayName: String = ""
    var order: Int = 0
    var manualOrder: Int? = nil
    var pinned: Bool = false
    var materialIDs: Set<String> = []
    var manualMaterialIDs: Set<String> = []
    var manualPaths: [String] = []
    var mergedIDs: Set<String> = []
    var evidence: [ProjectClassificationEvidence] = []
    var warnings: [String] = []
    var unavailable: Bool = false
    var name: String { displayName.isEmpty ? sourceName : displayName }
}

struct ProjectClassificationDraft: Sendable {
    var sources: [ProjectClassificationSource]
    var dimensions: [ProjectClassificationDimension]
    var warnings: [String]
}
