import Foundation

/// Text lives in the source Markdown. The library registry contains references only.
struct CharacterProfile: Codable, Equatable, Sendable {
    enum Review: String, Codable, CaseIterable, Sendable { case pending = "待补充", candidate = "候选", confirmed = "已确认" }
    struct Field: Codable, Equatable, Sendable {
        var text = ""
        var review: Review = .pending
        var evidence = ""
    }
    struct Asset: Identifiable, Codable, Equatable, Sendable {
        var id = UUID().uuidString
        var materialID: String
        var variant = "基础"
        var role = "补图"
        var stage = ""
        var status = "候选"
        var defaultUse = ""
        static let roles = ["主图", "高清图", "补图", "身形参考", "表情", "声线"]
        static let statuses = ["候选", "已确认", "历史停用"]
    }
    struct Story: Identifiable, Codable, Equatable, Sendable {
        var id = UUID().uuidString
        var episode = ""
        var summary = ""
        var source = ""
        var state = "后续规划"
    }
    var version = 1
    var projectID: String
    var characterID: String
    var fields: [String: Field] = [:]
    var assets: [Asset] = []
    var stories: [Story] = []
    var sources: [String] = []
    static let groups: [(String, [String])] = [
        ("人物介绍", ["姓名", "别名", "一句话身份", "年龄", "性别", "身高", "体重", "外貌", "戏份定位", "正反派／阵营", "性格", "经历", "能力", "人物关系", "标签"]),
        ("说话特点", ["用词习惯", "句式与节奏", "口头习惯", "对不同对象的变化", "代表台词"]),
        ("生成模板", ["固定特征", "可变部分", "禁改项", "图片提示词", "视频提示词", "声音提示词", "参考资产说明"])
    ]
    static var fieldNames: [String] { groups.flatMap(\.1) }
    var name: String { let value = fields["姓名"]?.text ?? ""; return value.isEmpty ? "未命名人物" : value }
    var hasConfirmedAsset: Bool { assets.contains { $0.status == "已确认" } }
    func matches(_ query: String) -> Bool {
        let corpus = ([characterID] + fields.values.map(\.text) + stories.map(\.summary) + assets.map(\.variant)).joined(separator: " ")
        return query.split(whereSeparator: { $0.isWhitespace || $0 == "+" }).allSatisfy { corpus.localizedCaseInsensitiveContains(String($0)) }
    }
    mutating func selectDefault(materialID: String, variant: String, role: String, stage: String) throws {
        for i in assets.indices where assets[i].stage == stage && (assets[i].role == role || assets[i].defaultUse == role) { assets[i].defaultUse = "" }
        if let i = assets.firstIndex(where: { $0.materialID == materialID && $0.variant == variant && $0.role == role && $0.stage == stage }) {
            assets[i].status = "已确认"; assets[i].defaultUse = role
        } else { assets.append(.init(materialID: materialID, variant: variant, role: role, stage: stage, status: "已确认", defaultUse: role)) }
        try validate()
    }
    func validate() throws {
        guard version == 1, !projectID.isEmpty, !characterID.isEmpty else { throw CharacterLibraryError.invalid("不支持的档案版本或缺少稳定 ID") }
        guard Set(assets.map(\.id)).count == assets.count, Set(stories.map(\.id)).count == stories.count else { throw CharacterLibraryError.invalid("资产或剧情记录 ID 重复") }
        for asset in assets {
            guard !asset.materialID.isEmpty, Asset.statuses.contains(asset.status), Asset.roles.contains(asset.role) else { throw CharacterLibraryError.invalid("资产引用、用途或状态无效") }
        }
        let defaults = assets.filter { $0.status == "已确认" && !$0.defaultUse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let keys = defaults.map { [$0.stage, $0.defaultUse].joined(separator: "\u{1F}") }
        guard Set(keys).count == keys.count else { throw CharacterLibraryError.invalid("同一阶段和用途只能有一个当前默认资产；请修改用途或将旧版标为历史停用") }
    }
}

enum CharacterLibraryError: LocalizedError {
    case invalid(String), conflict, missing
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .conflict: "文件已被外部修改。草稿仍保留，请复制草稿后重新读取并核对差异。"
        case .missing: "来源文件失联或无权限，未创建空文件替代。"
        }
    }
}
