import Foundation

enum ScriptAssetSearchScope: String, CaseIterable, Identifiable, Sendable {
    case recommended = "智能推荐"
    case locked = "已锁定"
    case library = "资产库"
    case project = "项目文件"
    var id: Self { self }
}

enum ScriptAssetMatchSource: Hashable, Sendable {
    case lockedVariant(variantID: String)
    case draftVariant(variantID: String, preferredMainID: String)
    case libraryAsset(assetID: String)
    case projectFile(recordID: String, path: String)

    var isLocked: Bool {
        if case .lockedVariant = self { return true }
        return false
    }

    var sourceLabel: String {
        switch self {
        case .lockedVariant: "已锁定形态"
        case .draftVariant: "待裁定形态"
        case .libraryAsset: "资产库单图"
        case .projectFile: "项目原图"
        }
    }
}

struct ScriptAssetMatch: Identifiable, Hashable, Sendable {
    var id: String
    var source: ScriptAssetMatchSource
    var title: String
    var subtitle: String
    var pathText: String
    var type: AssetType
    var score: Int
    var reasons: [String]
    var previewAsset: AssetItem
}

enum ScriptAssetMatcher {
    nonisolated static func matches(
        candidate: ScriptAssetCandidate,
        scope: ScriptAssetSearchScope,
        sortMode: ScriptAssetMatchSortMode = .balanced,
        search: String,
        projectID: String,
        projectName: String,
        assets: [AssetItem],
        variants: [AssetVariantRecord],
        entities: [AssetEntityRecord],
        projectImages: [ProjectImageIndexRecord],
        referenceFeaturePrint: Data? = nil
    ) -> [ScriptAssetMatch] {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        let memberIDs = Set(variants.flatMap(\.memberAssetIDs))
        let libraryPaths = Set(assets.compactMap { asset -> String? in
            guard !asset.imagePath.isEmpty else { return nil }
            return URL(fileURLWithPath: asset.imagePath).standardizedFileURL.path
        })
        var results: [ScriptAssetMatch] = []

        for variant in variants {
            guard let entity = entitiesByID[variant.entityID],
                  AssetStore.scriptAssetType(candidate.type, matches: entity.type),
                  let representativeID = variant.mainAssetID ?? Optional(variant.coverAssetID),
                  let representative = assetsByID[representativeID],
                  representative.deletedAt == nil else { continue }
            let source: ScriptAssetMatchSource = variant.isLocked
                ? .lockedVariant(variantID: variant.id)
                : .draftVariant(variantID: variant.id, preferredMainID: representative.id)
            guard scopeAllows(scope, source: source) else { continue }
            let title = "\(entity.name) · \(variant.effectiveVariantName)"
            let haystack = [title, variant.effectiveCallCode, variant.keyDifference ?? "", representative.searchableText]
                .joined(separator: " ")
            guard query(search, matches: haystack) else { continue }
            let ranking = rank(
                candidate: candidate,
                type: entity.type,
                text: haystack,
                locked: variant.isLocked,
                rating: representative.starRating,
                isMaster: representative.isMaster,
                resolution: representative.resolutionLabel,
                hasVision: false
            )
            results.append(ScriptAssetMatch(
                id: "VARIANT-\(variant.id)", source: source, title: title,
                subtitle: variant.isLocked ? variant.effectiveCallCode : "\(variant.memberAssetIDs.count) 张候选图",
                pathText: representative.sourceRelativePath ?? representative.originalFilename,
                type: entity.type, score: ranking.score, reasons: ranking.reasons,
                previewAsset: representative
            ))
        }

        if scope != .locked {
            for asset in assets where asset.deletedAt == nil && !memberIDs.contains(asset.id) {
                guard AssetStore.scriptAssetType(candidate.type, matches: asset.type) || asset.type == .unclassified else { continue }
                let source = ScriptAssetMatchSource.libraryAsset(assetID: asset.id)
                guard scopeAllows(scope, source: source) else { continue }
                let haystack = asset.searchableText
                guard query(search, matches: haystack) else { continue }
                let ranking = rank(
                    candidate: candidate, type: asset.type, text: haystack, locked: false,
                    rating: asset.starRating, isMaster: asset.isMaster,
                    resolution: asset.resolutionLabel, hasVision: !asset.normalizedTags.isEmpty
                )
                results.append(ScriptAssetMatch(
                    id: "ASSET-\(asset.id)", source: source, title: asset.name,
                    subtitle: asset.type == .unclassified ? "类型待确认" : asset.type.rawValue,
                    pathText: asset.sourceRelativePath ?? asset.originalFilename,
                    type: asset.type, score: ranking.score, reasons: ranking.reasons,
                    previewAsset: asset
                ))
            }
        }

        if scope == .recommended || scope == .project {
            for record in projectImages where !libraryPaths.contains(URL(fileURLWithPath: record.path).standardizedFileURL.path) {
                guard AssetStore.scriptAssetType(candidate.type, matches: record.effectiveType) || record.effectiveType == .unclassified else { continue }
                let source = ScriptAssetMatchSource.projectFile(recordID: record.id, path: record.path)
                let haystack = record.searchableText
                guard query(search, matches: haystack) else { continue }
                let ranking = rank(
                    candidate: candidate, type: record.effectiveType, text: haystack,
                    locked: false, rating: 0, isMaster: false,
                    resolution: record.resolutionLabel, hasVision: !record.visionLabels.isEmpty,
                    visualDistance: ProjectImageIndexer.featurePrintDistance(
                        referenceFeaturePrint, record.featurePrintData
                    )
                )
                results.append(ScriptAssetMatch(
                    id: "PROJECT-\(record.id)", source: source,
                    title: URL(fileURLWithPath: record.filename).deletingPathExtension().lastPathComponent,
                    subtitle: record.visionLabels.isEmpty ? record.effectiveType.rawValue : "本机识图 · \(record.effectiveType.rawValue)",
                    pathText: record.relativePath,
                    type: record.effectiveType, score: ranking.score, reasons: ranking.reasons,
                    previewAsset: record.previewAsset(projectID: projectID, projectName: projectName)
                ))
            }
        }

        return sorted(results, mode: sortMode).prefix(400).map { $0 }
    }

    nonisolated static func sorted(
        _ results: [ScriptAssetMatch],
        mode: ScriptAssetMatchSortMode
    ) -> [ScriptAssetMatch] {
        results.sorted {
            if mode == .nameFirst {
                let leftNameMatch = $0.reasons.contains("名称匹配")
                let rightNameMatch = $1.reasons.contains("名称匹配")
                if leftNameMatch != rightNameMatch { return leftNameMatch }

                if leftNameMatch && rightNameMatch {
                    let leftFormMatch = $0.reasons.contains("形态匹配")
                    let rightFormMatch = $1.reasons.contains("形态匹配")
                    if leftFormMatch != rightFormMatch { return leftFormMatch }
                }
            }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private nonisolated static func scopeAllows(
        _ scope: ScriptAssetSearchScope,
        source: ScriptAssetMatchSource
    ) -> Bool {
        switch scope {
        case .recommended: true
        case .locked: source.isLocked
        case .library:
            if case .projectFile = source { false } else { true }
        case .project:
            if case .projectFile = source { true } else { false }
        }
    }

    private nonisolated static func query(_ search: String, matches text: String) -> Bool {
        let words = search
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
        guard !words.isEmpty else { return true }
        let value = text.lowercased()
        return words.allSatisfy(value.contains)
    }

    private nonisolated static func rank(
        candidate: ScriptAssetCandidate,
        type: AssetType,
        text: String,
        locked: Bool,
        rating: Int,
        isMaster: Bool,
        resolution: String,
        hasVision: Bool,
        visualDistance: Float? = nil
    ) -> (score: Int, reasons: [String]) {
        let value = text.lowercased()
        var score = 0
        var reasons: [String] = []
        if type == candidate.type { score += 42; reasons.append("类型一致") }
        else if type == .unclassified { score += 4 }
        else { score += 30; reasons.append("类型兼容") }
        if !candidate.name.isEmpty, value.contains(candidate.name.lowercased()) {
            score += 34; reasons.append("名称匹配")
        }
        let form = candidate.effectiveFormName.lowercased()
        if !form.isEmpty, value.contains(form) { score += 18; reasons.append("形态匹配") }
        if locked { score += 16; reasons.append("已锁定") }
        if isMaster { score += 10; reasons.append("精选资产") }
        if rating > 0 { score += rating * 2; reasons.append("\(rating) 星") }
        if resolution == "4K" { score += 5; reasons.append("4K") }
        else if resolution == "2K" { score += 3; reasons.append("2K") }
        if hasVision { score += 5; reasons.append("已识图") }
        if let visualDistance {
            if visualDistance <= 0.18 { score += 32; reasons.append("外观高度相似") }
            else if visualDistance <= 0.36 { score += 20; reasons.append("外观相似") }
            else if visualDistance <= 0.55 { score += 8; reasons.append("视觉参考相近") }
        }
        return (score, Array(reasons.prefix(4)))
    }
}

private extension AssetItem {
    var searchableText: String {
        [
            name, originalFilename, sourceRelativePath ?? "", assetDescription, note,
            type.rawValue, category.rawValue, normalizedTags.joined(separator: " ")
        ].joined(separator: " ")
    }
}
