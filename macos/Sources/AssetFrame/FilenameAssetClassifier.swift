import Foundation

enum FilenameAssetClassifier {
    struct Result: Equatable, Sendable {
        var type: AssetType
        var category: AssetCategory
        var evidence: [String]
    }

    private struct Rule: Sendable {
        var type: AssetType
        var terms: [String]
    }

    private static let rules: [Rule] = [
        Rule(type: .publishCover, terms: ["发布封面", "竖版封面", "thumbnail"]),
        Rule(type: .fixedSymbol, terms: ["固定视觉", "视觉符号", "logo", "标志", "标识"]),
        Rule(type: .boundStructure, terms: ["绑定结构", "结构绑定", "boundstructure"]),
        Rule(type: .cover, terms: ["封面", "海报", "cover", "poster"]),
        Rule(type: .product, terms: ["产品", "商品", "包装", "product", "sku"]),
        Rule(type: .person, terms: ["人物", "角色", "主角", "男主", "女主", "群像", "character", "portrait"]),
        Rule(type: .creature, terms: ["生物", "怪物", "动物", "灵兽", "creature", "monster", "animal"]),
        Rule(type: .scene, terms: ["场景", "背景", "环境", "室内", "室外", "房间", "街道", "山水", "scene", "background"]),
        Rule(type: .venue, terms: ["场地", "建筑", "venue", "architecture"]),
        Rule(type: .prop, terms: ["道具", "武器", "配饰", "饰品", "家具", "器物", "载具", "prop", "weapon", "tool"])
    ]

    private static let commonTerms = ["通用", "公共资产", "共享资产", "固定视觉", "common", "shared"]

    nonisolated static func classify(path: String) -> Result {
        let value = normalized(path)
        for rule in rules {
            let matches = rule.terms.filter(value.contains)
            guard !matches.isEmpty else { continue }
            let commonMatches = commonTerms.filter(value.contains)
            return Result(
                type: rule.type,
                category: commonMatches.isEmpty ? .project : .common,
                evidence: Array(Set(matches + commonMatches)).sorted()
            )
        }
        let commonMatches = commonTerms.filter(value.contains)
        return Result(
            type: .unclassified,
            category: commonMatches.isEmpty ? .pending : .common,
            evidence: Array(Set(commonMatches)).sorted()
        )
    }

    nonisolated private static func normalized(_ path: String) -> String {
        path
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "_")
    }
}
