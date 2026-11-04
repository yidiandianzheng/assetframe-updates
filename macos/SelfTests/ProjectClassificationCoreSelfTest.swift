import Foundation

#if PROJECT_CLASSIFICATION_CORE_SELF_TEST
// 此入口只用于独立纯核心自测；完整 App 构建继续使用 Models.swift 的真实类型。
struct MaterialRecord: Sendable {
    var id: String
    var sourcePath: String?
    var sourceLocations: [String] = []
    var deletedAt: Date? = nil
}

@main
struct ProjectClassificationCoreSelfTest {
    static func main() throws {
        let fm = FileManager.default
        let base = "/tmp/assetframe-qa.pcat-20261026-01/core-selftest-" + UUID().uuidString
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        let root = base + "/茶业务 中文"
        let story = base + "/剧情项目"
        for directory in [root, story, root + "/assets", root + "/assets/角色", root + "/assets2", root + "/设定", root + "/其他", root + "/历史备份", story + "/设定"] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        func write(_ relative: String, _ content: String = "fixture") throws {
            try content.write(toFile: base + "/" + relative, atomically: true, encoding: .utf8)
        }
        try write("茶业务 中文/assets/角色/人物 甲.png")
        try write("茶业务 中文/assets/产品.png")
        try write("茶业务 中文/assets2/边界.png")
        try write("茶业务 中文/设定/人物.md", "人物设定不自动关联图片。")
        try write("茶业务 中文/其他/人物.md")
        try write("茶业务 中文/历史备份/旧索引.md")
        try write("剧情项目/设定/世界规则.md", "状态统计 999 不代表素材数量。")
        try write("外部.png")
        try fm.createSymbolicLink(atPath: root + "/逃逸.png", withDestinationPath: base + "/外部.png")
        try fm.createSymbolicLink(atPath: root + "/跳转", withDestinationPath: root + "/assets")
        let index = root + "/资产索引.md"
        let text = """
        # 资产表
        | 名称 | type | 图片路径 | SHA256 |
        | --- | --- | --- | --- |
        | 人物一 | 人物 | [[assets/角色/人物 甲.png\\|甲]] | 123 |
        | 产品一 | 产品 | [包装](<assets/产品.png>) | 456 |
        | 未入库 | 其他 | ![边界](assets2/边界.png) | 789 |

        ## 目录导航 [优先级:2]
        - [角色目录](assets/角色/)
        - [资产目录](assets/)
        - [[设定/人物|人物设定]]
        - [[人物|同名多义]]
        - [失效](assets/不存在.png)
        - [越界](../外部.png)
        - [符号链接](逃逸.png)
        - [内部符号目录](跳转/)
        """
        try text.write(toFile: index, atomically: true, encoding: .utf8)
        let extra = root + "/补充索引.md"
        try """
        # 补充
        | 名称 | 类型 | 路径 |
        | --- | --- | --- |
        | 第二个人物 | 人物 | assets/角色/人物 甲.png |
        """.write(toFile: extra, atomically: true, encoding: .utf8)
        let storyIndex = story + "/主题索引.md"
        try """
        # 主题索引
        ## 世界设定
        - [[设定/世界规则|世界与规则]]
        - 状态统计：999
        """.write(toFile: storyIndex, atomically: true, encoding: .utf8)
        let a = MaterialRecord(id: "a", sourcePath: root + "/assets/角色/人物 甲.png")
        let b = MaterialRecord(id: "b", sourcePath: root + "/assets/产品.png")
        let c = MaterialRecord(id: "c", sourcePath: root + "/assets2/边界.png")
        let outside = MaterialRecord(id: "outside", sourcePath: base + "/外部.png")
        let removed = MaterialRecord(id: "deleted", sourcePath: root + "/assets/产品.png", deletedAt: Date())
        let materials = [a, b, c, outside, removed]
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            checks += 1
            if !condition() { throw NSError(domain: "ProjectClassificationCoreSelfTest", code: checks, userInfo: [NSLocalizedDescriptionKey: "失败：" + label]) }
        }
        let discovered = try ProjectClassificationParser.discover(roots: [root])
        try expect(discovered.contains(ProjectClassificationParser.canonical(index)), "发现候选索引")
        try expect(!discovered.contains(where: { $0.contains("历史备份") }), "排除历史备份")
        try expect(!discovered.contains(where: { $0.contains("跳转") }), "不跟随符号链接")
        let draft = try ProjectClassificationParser.parse(roots: [root], indexPaths: [index, extra, index], materials: [a, b, outside, removed])
        try expect(draft.sources.count == 2, "多索引合并并去重来源")
        try expect(draft.sources.allSatisfy { $0.fingerprint.count == 64 }, "SHA256 来源指纹")
        let type = try required(draft.dimensions.first { $0.sourceName == "类型" }, "类型维度")
        try expect(draft.dimensions.count == 2, "名称与 SHA 不生成维度")
        let person = try required(type.options.first { $0.sourceName == "人物" }, "人物选项")
        let product = try required(type.options.first { $0.sourceName == "产品" }, "产品选项")
        try expect(person.materialIDs == ["a"], "中文空格、转义双链别名与裸表格路径")
        try expect(person.evidence.count == 2, "同类型多索引证据合并")
        try expect(product.materialIDs == ["b"], "标准链接与尖括号路径")
        let navigation = try required(draft.dimensions.first { $0.sourceName == "目录导航" }, "导航维度")
        let folder = try required(navigation.options.first { $0.sourceName == "资产目录" }, "目录选项")
        try expect(folder.materialIDs == ["a", "b"], "目录边界不匹配 assets2")
        let roleFolder = try required(navigation.options.first { $0.sourceName == "角色目录" }, "角色目录")
        let document = try required(navigation.options.first { $0.sourceName == "人物设定" }, "文档候选")
        try expect(document.materialIDs.isEmpty, "省略 md 扩展文档仅导航")
        try expect(document.warnings.contains { $0.contains("文档") }, "文档导航提示")
        try expect(draft.warnings.contains { $0.contains("重名多义") }, "双链重名歧义提示")
        try expect(draft.warnings.contains { $0.contains("越出") }, "越界提示")
        try expect(draft.warnings.contains { $0.contains("符号链接") }, "符号链接提示")
        try expect(draft.warnings.contains { $0.contains("失效") }, "失效提示")
        try expect(draft.warnings.contains { $0.contains("尚未入库") }, "未入库媒体提示")
        var profile = ProjectClassificationProfile(name: "茶业务", roots: [root])
        profile = ProjectClassificationParser.adopting(draft, into: profile)
        try expect(profile.memberIDs(materials: materials) == ["a", "b", "c"], "限定项目、排除已删除、范围外素材")
        try expect(profile.matchingIDs(materials: materials) == ["a", "b", "c"], "空条件不限")
        profile.selected = [type.id: [person.id, product.id]]
        try expect(profile.matchingIDs(materials: materials) == ["a", "b"], "同维度 OR")
        profile.selected[navigation.id] = [roleFolder.id]
        try expect(profile.matchingIDs(materials: materials) == ["a"], "跨维度 AND")
        try expect(profile.optionCount(product, dimensionID: type.id, materials: materials) == 0, "计数保留另一维度")
        profile.selected = [type.id: [person.id]]
        try expect(profile.optionCount(product, dimensionID: type.id, materials: materials) == 1, "计数忽略本维度")
        try expect(profile.matchingIDs(materials: materials).intersection(["b"]).isEmpty, "可以与旧条件交集组合")
        profile.selected = [type.id: ["unknown-option"]]
        try expect(profile.matchingIDs(materials: materials).isEmpty, "未知选项零命中")
        profile.selected = ["unknown-dimension": ["unknown-option"]]
        try expect(profile.matchingIDs(materials: materials).isEmpty, "未知维度零命中")
        profile.selected = [type.id: [person.id]]
        let d = try required(profile.dimensions.firstIndex { $0.id == type.id }, "维度下标")
        let p = try required(profile.dimensions[d].options.firstIndex { $0.id == person.id }, "人物下标")
        profile.dimensions[d].displayName = "手改类型"
        profile.dimensions[d].manualOrder = 9
        profile.dimensions[d].pinned = true
        profile.dimensions[d].options[p].displayName = "人工人物"
        profile.dimensions[d].options[p].pinned = true
        profile.dimensions[d].options[p].manualOrder = 8
        profile.dimensions[d].options[p].manualMaterialIDs = ["c", "outside"]
        profile.dimensions[d].options[p].manualPaths = [root + "/assets2", base]
        profile.dimensions[d].options[p].mergedIDs = [product.id]
        profile.dimensions[d].options[p].materialIDs.formUnion(product.materialIDs)
        profile.dimensions[d].options.removeAll { $0.id == product.id }
        // 插入空行/重排其他行不会影响语义 ID。
        try ("\n\n" + text).write(toFile: index, atomically: true, encoding: .utf8)
        let refreshed = try ProjectClassificationParser.parse(roots: [root], indexPaths: [index, extra], materials: [a, b, outside, removed])
        try expect(refreshed.dimensions.first { $0.id == type.id }?.options.contains { $0.id == person.id } == true, "稳定 ID 不依赖行号")
        let updated = ProjectClassificationParser.adopting(refreshed, into: profile)
        let updatedType = try required(updated.dimensions.first { $0.id == type.id }, "刷新类型")
        let updatedPerson = try required(updatedType.options.first { $0.id == person.id }, "刷新人物")
        try expect(updatedType.displayName == "手改类型" && updatedType.pinned && updatedType.manualOrder == 9, "继承维度显示名置顶和人工顺序")
        try expect(updatedPerson.displayName == "人工人物" && updatedPerson.pinned && updatedPerson.manualOrder == 8, "继承选项显示名置顶人工顺序")
        try expect(Set(updatedPerson.manualPaths) == Set(profile.dimensions[d].options[p].manualPaths), "保留人工路径原记录")
        try expect(updatedPerson.manualMaterialIDs == ["c", "outside"], "保留人工素材")
        try expect(!updatedType.options.contains { $0.id == product.id }, "刷新不恢复已合并源选项")
        try expect(updatedPerson.materialIDs == ["a", "b"], "合并成员刷新重新折入目标")
        try expect(updated.matchingIDs(materials: materials) == ["a", "b", "c"], "人工关联限定项目根并去重")
        try expect(updated.selected == profile.selected, "选择继承")
        let batch = updated.evaluation(materials: materials)
        try expect(batch.matchingIDs == updated.matchingIDs(materials: materials), "批量查询匹配等价")
        try expect(updated.dimensions.allSatisfy { dimension in
            dimension.options.allSatisfy { option in
                batch.counts[dimension.id]?[option.id] == updated.optionCount(option, dimensionID: dimension.id, materials: materials)
            }
        }, "批量计数与逐项计数等价")
        let encoded = try JSONEncoder().encode(updated)
        let decoded = try JSONDecoder().decode(ProjectClassificationProfile.self, from: encoded)
        try expect(decoded == updated, "配置 Codable 往返")
        let emptyDraft = ProjectClassificationDraft(sources: [], dimensions: [], warnings: [])
        let unavailable = ProjectClassificationParser.adopting(emptyDraft, into: ProjectClassificationParser.adopting(draft, into: ProjectClassificationProfile(name: "old", roots: [root])))
        let missing = try required(unavailable.dimensions.first { $0.id == type.id }?.options.first { $0.id == person.id }, "旧选项保留")
        try expect(missing.unavailable && missing.materialIDs.isEmpty, "失效选项不自动匹配")
        var unavailableChosen = unavailable
        unavailableChosen.selected = [type.id: [person.id]]
        try expect(unavailableChosen.matchingIDs(materials: materials).isEmpty, "失效旧选择零命中")
        let storyDraft = try ProjectClassificationParser.parse(roots: [story], indexPaths: [storyIndex], materials: materials)
        try expect(storyDraft.dimensions.flatMap(\.options).allSatisfy { $0.materialIDs.isEmpty }, "剧情文档不能推图或使用统计数")
        let other = try ProjectClassificationParser.parse(roots: [root, story], indexPaths: [index], materials: materials)
        try expect(other.dimensions.first { $0.sourceName == "类型" }?.id != type.id, "不同项目根 ID 隔离")
        let duplicate = MaterialRecord(id: "duplicate", sourcePath: a.sourcePath)
        let ambiguous = try ProjectClassificationParser.parse(roots: [root], indexPaths: [index], materials: [a, b, duplicate])
        try expect(ambiguous.dimensions.first { $0.sourceName == "类型" }?.options.first { $0.sourceName == "人物" }?.materialIDs.isEmpty == true, "同媒体路径多素材不自动选择")
        let snapshot = updated
        var parseFailed = false
        do { _ = try ProjectClassificationParser.parse(roots: [root], indexPaths: [root + "/丢失.md"], materials: materials) }
        catch { parseFailed = true }
        try expect(parseFailed && snapshot == updated, "失败保留旧快照")
        let freshFingerprint = try ProjectClassificationParser.fingerprint(index)
        try expect(freshFingerprint == refreshed.sources.first { $0.path == ProjectClassificationParser.canonical(index) }?.fingerprint, "采用前指纹可核验")
        try "\n漂移".write(toFile: index, atomically: true, encoding: .utf8)
        let driftFingerprint = try ProjectClassificationParser.fingerprint(index)
        try expect(driftFingerprint != freshFingerprint, "来源漂移可检测")
        try expect(!ProjectClassificationParser.isWithin(root + "-other/file.png", roots: [root]), "根目录严格边界")
        try expect(!ProjectClassificationParser.isSafePath(root + "/跳转/角色/人物 甲.png", roots: [root]), "根内符号目录拒绝")
        var ordering = updated
        ordering.dimensions[0].manualOrder = nil
        ordering.dimensions[0].pinned = false
        if ordering.dimensions.count > 1 {
            ordering.dimensions[1].manualOrder = -1
            try expect(ordering.orderedDimensions.first?.id == ordering.dimensions[1].id, "人工顺序覆盖索引优先级")
        }
        let providedFixtures = "/tmp/assetframe-qa.pcat-20261026-01/fixtures"
        if fm.fileExists(atPath: providedFixtures + "/茶业务示例/资产索引.md") {
            let providedRoot = providedFixtures + "/茶业务示例"
            let fixtureMaterials = ["人物甲", "产品甲", "场景甲"].map {
                MaterialRecord(id: $0, sourcePath: providedRoot + "/assets/" + $0 + ".png")
            }
            let provided = try ProjectClassificationParser.parse(roots: [providedRoot], indexPaths: [providedRoot + "/资产索引.md"], materials: fixtureMaterials)
            try expect(provided.dimensions.first { $0.sourceName == "类型" }?.options.count == 3, "任务书茶业务样例三个类型")
            try expect(provided.dimensions.first { $0.sourceName == "类型" }?.options.first { $0.sourceName == "人物" }?.materialIDs == ["人物甲"], "任务书样例双重转义竖线")
            let providedStory = providedFixtures + "/剧情示例"
            let providedStoryDraft = try ProjectClassificationParser.parse(roots: [providedStory], indexPaths: [providedStory + "/索引.md"], materials: fixtureMaterials)
            try expect(providedStoryDraft.dimensions.flatMap(\.options).allSatisfy { $0.materialIDs.isEmpty }, "任务书剧情样例无虚构素材数")
            try expect(providedStoryDraft.dimensions.flatMap(\.options).contains { $0.sourceName == "地理行政区" }, "非类型表格内双链导航")
        }
        let tooLarge = root + "/超大索引.md"
        try String(repeating: "x", count: 2_000_001).write(toFile: tooLarge, atomically: true, encoding: .utf8)
        var oversizedFailed = false
        do { _ = try ProjectClassificationParser.parse(roots: [root], indexPaths: [tooLarge], materials: materials) }
        catch { oversizedFailed = true }
        try expect(oversizedFailed, "超大索引明确拒绝")
        let symlinkIndex = root + "/别名索引.md"
        try fm.createSymbolicLink(atPath: symlinkIndex, withDestinationPath: index)
        var symlinkFailed = false
        do { _ = try ProjectClassificationParser.parse(roots: [root], indexPaths: [symlinkIndex], materials: materials) }
        catch { symlinkFailed = true }
        try expect(symlinkFailed, "拒绝直接选择符号索引")
        try "# 内部索引".write(toFile: root + "/assets/内部索引.md", atomically: true, encoding: .utf8)
        var fingerprintSymlinkFailed = false
        do { _ = try ProjectClassificationParser.fingerprint(root + "/跳转/内部索引.md") }
        catch { fingerprintSymlinkFailed = true }
        try expect(fingerprintSymlinkFailed, "来源漂移核验不跟随父目录符号链接")
        print("项目分类核心自测通过：\(checks) 项；全部合成数据位于临时隔离根，未访问生产库。")
    }

    private static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw NSError(domain: "ProjectClassificationCoreSelfTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少：" + label]) }
        return value
    }
}
#endif
