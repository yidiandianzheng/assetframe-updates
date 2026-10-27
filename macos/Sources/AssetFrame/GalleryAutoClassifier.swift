import Foundation

/// 图库自动分类：导入图片时按「文件名 > 产品线 > 目录名」把素材归入品牌 / 茶类 / 产品线 / 机位 / 验收。
///
/// 纯本地规则，不调用模型、不联网；判定结果写进 `MaterialRecord.classification`，
/// 与手工分类共用同一套词表与筛选，因此检查器、筛选、CSV、CLI、撤销都能直接看到。
///
/// 规则说明见 `图库分类/分类规则.md`，取值与别名见
/// `macos/Documentation/资产分类词表/词表_v0.1.json`（由 `生成词表Swift.py` 生成到 `ClassificationVocabulary`）。
enum GalleryAutoClassifier {
    struct Result: Equatable, Sendable {
        var values: [String: [String]] = [:]
        var evidence: [String: String] = [:]
        var conflicts: [String] = []
        var isEmpty: Bool { values.isEmpty }
    }

    /// 项目 / 库容器名：出现在每条路径里，不参与品牌判定。
    /// 不排除的话，路径里的「中茶木兰姐」会让整库都命中「中茶」。
    static let projectRootNames: Set<String> = [
        "中茶木兰姐", "01_公共资产库", "02_商业内容", "Codex工作区", "Codex客户储存", "木兰姐", "香万家木兰"
    ]

    /// 机位按此顺序优先匹配（长词在前），避免「高机位斜侧面」被判成「侧面」。
    private static let shotPriority = [
        "高机位斜侧面", "斜侧面", "正面", "侧面", "背面", "顶部俯视", "底部", "近景", "特写", "全景"
    ]

    /// 图类型按此顺序优先匹配：越具体的越靠前，避免「透明PNG」被「包装」抢走。
    private static let assetKindPriority = [
        "透明素材", "字体字样", "对比图", "平面设计稿", "包装设计稿", "视频抽帧", "PPT页面", "实拍照片"
    ]

    /// 用途按此顺序优先匹配；都不命中时产品图记「设计素材」。
    /// 前面的词是设计过程状态（定稿/候选/参考…），后面才是投放用途（详情页/主图/海报…），
    /// 因为这一库产品图绝大多数是过程稿，先判状态才有区分度。
    private static let usagePriority = [
        "定稿", "补图", "已确认", "候选", "参考",
        "详情页", "短视频封面", "商品主图", "社媒海报"
    ]

    /// 规则没命中时写下的占位值：它不是判断结果，只是「暂归此类」，
    /// 后续规则升级后允许被真正的命中值替换（见 `GlobalMaterialStore.backfillGalleryClassification`）。
    static let placeholderTerms = ["设计素材"]

    private struct LineRelation: Sendable {
        var brand: String?
        var tea: String?
    }

    /// 产品线 → 品牌 / 茶类。词表里只存产品线名称，关系表在这里维护，
    /// 与 `图库分类/产品名称映射表.json` 同源；改一处要同步另一处。
    private static let productLineRelations: [String: LineRelation] = [
        "东方奇种·茶盈航异形罐": LineRelation(brand: "茶盈航", tea: "乌龙茶"),
        "香万家·正山小种红金礼盒": LineRelation(brand: "香万家", tea: "红茶"),
        "香万家·金骏眉橙色礼盒": LineRelation(brand: "香万家", tea: "红茶"),
        "海南红茶·引流款情绪包装": LineRelation(brand: "香万家", tea: "红茶"),
        "铁观音茶罐": LineRelation(brand: nil, tea: "乌龙茶"),
        "乌龙茶·同系列泡袋": LineRelation(brand: nil, tea: "乌龙茶"),
        "岁三窖·陶罐": LineRelation(brand: "岁三窖", tea: nil),
        "岁三窖·茶会": LineRelation(brand: "岁三窖", tea: nil),
        "中茶·大红袍金罐": LineRelation(brand: "中茶", tea: "乌龙茶"),
        "中茶·红韵": LineRelation(brand: "中茶", tea: "红茶"),
        "千茶素材·乌龙茶": LineRelation(brand: "千茶素材", tea: "乌龙茶")
    ]

    // MARK: - 入口

    /// - Parameters:
    ///   - path: 素材的完整路径（用于目录判定与验收状态）。
    ///   - filename: 原始文件名；不传则取路径最后一段。
    ///   - pixelWidth/pixelHeight: 画面像素尺寸，用于判定比例；未知传 0。
    nonisolated static func classify(path: String, filename: String? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0) -> Result {
        let fullPath = path.precomposedStringWithCanonicalMapping
        let name = (filename ?? URL(fileURLWithPath: fullPath).lastPathComponent)
            .precomposedStringWithCanonicalMapping
        let segments = fullPath.split(separator: "/").map(String.init).filter { !projectRootNames.contains($0) }
        let folder = segments.dropLast().joined(separator: " ")
        /// 电商分类只对产品图生效；PPT、人物、分镜等素材不挂电商标签。
        let isProductImage = fullPath.contains("/04_产品/")

        var result = Result()

        // 产品线：文件名优先，其次目录；同一层取最长命中，先确定它，品牌和茶类可以回退到它。
        let productLine = longestHit(name, in: "product_line") ?? longestHit(folder, in: "product_line")
        if let productLine {
            result.values["product_line"] = [productLine]
            result.evidence["product_line"] = "文件名/目录"
        }

        // 品牌：文件名 > 产品线 > 目录名
        if let brand = longestHit(name, in: "brand") {
            result.values["brand"] = [brand]
            result.evidence["brand"] = "文件名"
        } else if let line = productLine, let brand = productLineRelations[line]?.brand {
            result.values["brand"] = [brand]
            result.evidence["brand"] = "产品线"
        } else if let brand = longestHit(folder, in: "brand") {
            result.values["brand"] = [brand]
            result.evidence["brand"] = "目录名"
        }

        // 茶类：文件名 > 目录 > 产品线
        if let tea = longestHit(name, in: "tea_type") {
            result.values["tea_type"] = [tea]
            result.evidence["tea_type"] = "文件名"
        } else if let tea = longestHit(folder, in: "tea_type") {
            result.values["tea_type"] = [tea]
            result.evidence["tea_type"] = "目录名"
        } else if let line = productLine, let tea = productLineRelations[line]?.tea {
            result.values["tea_type"] = [tea]
            result.evidence["tea_type"] = "产品线"
        }

        // 茶类冲突：文件/目录结论与产品线标注不一致时保留前者并记录
        if let line = productLine,
           let declared = productLineRelations[line]?.tea,
           let decided = result.values["tea_type"]?.first,
           decided != declared {
            result.conflicts.append("茶类冲突：命名判为「\(decided)」，产品线标注「\(declared)」")
        }

        // 机位：按固定优先级，文件名优先于目录
        if let shot = shotHit(name) ?? shotHit(folder) {
            result.values["shot"] = [shot]
            result.evidence["shot"] = shotHit(name) == nil ? "目录名" : "文件名"
        }

        // 验收：路径里没有结论就不写，缺省按「待核」展示
        if fullPath.contains("已确认") || fullPath.contains("已確認") {
            result.values["acceptance"] = ["已确认"]
            result.evidence["acceptance"] = "路径"
        } else if fullPath.contains("待确认") || fullPath.contains("待確認") {
            result.values["acceptance"] = ["待确认"]
            result.evidence["acceptance"] = "路径"
        }

        // 图类型：所有图片都判，属于通用事实
        if let kind = priorityHit(name, order: assetKindPriority, dimension: "asset_kind")
            ?? priorityHit(folder, order: assetKindPriority, dimension: "asset_kind") {
            result.values["asset_kind"] = [kind]
            result.evidence["asset_kind"] = "文件名/目录"
        }

        // 比例：用像素尺寸判；SVG 记矢量，拿不到尺寸就不写
        if let ratio = ratioLabel(width: pixelWidth, height: pixelHeight, filename: name) {
            result.values["ratio"] = [ratio]
            result.evidence["ratio"] = "像素尺寸"
        }

        // 用途与整理状态只对产品图写，避免给 PPT、人物、分镜这些素材挂电商标签
        if isProductImage {
            if let usage = priorityHit(name, order: usagePriority, dimension: "usage")
                ?? priorityHit(folder, order: usagePriority, dimension: "usage") {
                result.values["usage"] = [usage]
                result.evidence["usage"] = "文件名/目录"
            } else {
                result.values["usage"] = Self.placeholderTerms
                result.evidence["usage"] = "默认"
            }
            let accepted = result.values["acceptance"]?.first == "已确认"
            let complete = result.values["brand"] != nil && result.values["tea_type"] != nil
            if accepted && complete {
                result.values["organize_status"] = ["可用"]
            } else if accepted {
                result.values["organize_status"] = ["待补标签"]
            } else {
                result.values["organize_status"] = ["待整理"]
            }
            result.evidence["organize_status"] = "验收 + 品牌/茶类完整度"
        }

        return result
    }

    /// 导入时写入的分类；没有任何命中就不写，保持「未分类」。
    nonisolated static func classification(path: String, filename: String? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0) -> MaterialClassification? {
        let result = classify(path: path, filename: filename, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        return result.isEmpty ? nil : MaterialClassification(values: result.values)
    }

    // MARK: - 匹配

    /// 在同一维度里取「最长命中」的候选词，返回标准词。
    /// 权重按实际命中的那个词算，不是按词条里最长的别名算——否则短别名会借长标准名抢走匹配。
    private nonisolated static func longestHit(_ text: String, in dimension: String) -> String? {
        guard !text.isEmpty else { return nil }
        var best: (canonical: String, length: Int)?
        for term in ClassificationVocabulary.terms(in: dimension) {
            for key in [term.canonical] + term.aliases where text.contains(key) {
                if best == nil || key.count > best!.length {
                    best = (term.canonical, key.count)
                }
            }
        }
        return best?.canonical
    }

    private nonisolated static func shotHit(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        for canonical in shotPriority {
            guard let term = ClassificationVocabulary.term(canonical, in: "shot") else { continue }
            if text.contains(term.canonical) || term.aliases.contains(where: text.contains) {
                return canonical
            }
        }
        return nil
    }

    /// 按给定优先级在词表里找第一个命中的词条。
    private nonisolated static func priorityHit(_ text: String, order: [String], dimension: String) -> String? {
        guard !text.isEmpty else { return nil }
        for canonical in order {
            guard let term = ClassificationVocabulary.term(canonical, in: dimension) else { continue }
            if text.contains(term.canonical) || term.aliases.contains(where: text.contains) {
                return canonical
            }
        }
        return nil
    }

    /// 常用比例的标准值，用于容差比较。
    private static let ratioTargets: [(value: Double, label: String)] = [
        (1.0, "1:1"), (1.3333, "4:3"), (0.75, "3:4"), (1.7778, "16:9"),
        (0.5625, "9:16"), (1.5, "3:2"), (0.6667, "2:3")
    ]

    /// 画面比例；SVG 记「矢量」，没有尺寸返回 nil（不写该维度）。
    private nonisolated static func ratioLabel(width: Int, height: Int, filename: String) -> String? {
        if filename.lowercased().hasSuffix(".svg") { return "矢量" }
        guard width > 0, height > 0 else { return nil }
        let divisor = greatestCommonDivisor(width, height)
        let key = String(width / divisor) + ":" + String(height / divisor)
        let exactKeys = ["1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3"]
        if exactKeys.contains(key) { return key }
        let value = Double(width) / Double(height)
        for target in ratioTargets {
            if abs(value - target.value) <= 0.02 { return target.label }
        }
        return "其他"
    }

    private nonisolated static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}
