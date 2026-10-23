import Foundation

/// 受控分类：维度 id → 该维度的标准词（来自内置 `ClassificationVocabulary`）。
/// 与备注分离：备注是自由说明，分类只存受控值；旧库没有该字段时按未分类处理。
struct MaterialClassification: Codable, Hashable, Sendable {
    /// 只保留非空字符串并去重；未知维度/未知词保留（词表升级后可继续查看和移除），
    /// 展示与筛选时再按词表顺序排序。
    private(set) var values: [String: [String]]

    init(values: [String: [String]] = [:]) {
        self.values = Self.normalized(values)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = Self.normalized(try container.decode([String: [String]].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    static func normalized(_ input: [String: [String]]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (dimension, terms) in input {
            let cleaned = terms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var seen = Set<String>()
            let unique = cleaned.filter { seen.insert($0).inserted }
            guard !unique.isEmpty else { continue }
            result[dimension] = ordered(unique, dimension: dimension)
        }
        return result
    }

    private static func ordered(_ terms: [String], dimension: String) -> [String] {
        let order = Dictionary(uniqueKeysWithValues: ClassificationVocabulary.terms(in: dimension).enumerated().map { ($1.canonical, $0) })
        return terms.sorted { lhs, rhs in
            let left = order[lhs] ?? Int.max
            let right = order[rhs] ?? Int.max
            return left == right ? lhs < rhs : left < right
        }
    }

    var isEmpty: Bool { values.isEmpty }
    var termCount: Int { values.values.reduce(0) { $0 + $1.count } }
    var allTerms: [String] { values.values.flatMap { $0 } }

    func terms(for dimension: String) -> [String] { values[dimension] ?? [] }
    func contains(_ term: String, in dimension: String) -> Bool { values[dimension]?.contains(term) == true }

    mutating func set(_ terms: [String], for dimension: String) {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = cleaned.filter { seen.insert($0).inserted }
        if unique.isEmpty { values.removeValue(forKey: dimension) } else { values[dimension] = Self.ordered(unique, dimension: dimension) }
    }

    mutating func toggle(_ term: String, in dimension: String) {
        let expanded = ClassificationVocabulary.allowsMultiple(dimension)
        if contains(term, in: dimension) {
            remove(term, in: dimension)
        } else if expanded {
            add(term, in: dimension)
        } else {
            set([term], for: dimension)
        }
    }

    mutating func add(_ term: String, in dimension: String) {
        var current = values[dimension] ?? []
        guard !current.contains(term) else { return }
        current.append(term)
        set(current, for: dimension)
    }

    mutating func remove(_ term: String, in dimension: String) {
        var current = values[dimension] ?? []
        current.removeAll { $0 == term }
        set(current, for: dimension)
    }

    mutating func clear(_ dimension: String) { values.removeValue(forKey: dimension) }

    mutating func removeAll() { values.removeAll() }

    /// 维度之间是「且」，同维度多选是「或」；空的筛选条件不限制。
    func matches(_ filter: [String: Set<String>]) -> Bool {
        for (dimension, wanted) in filter where !wanted.isEmpty {
            guard let mine = values[dimension], !Set(mine).isDisjoint(with: wanted) else { return false }
        }
        return true
    }

    /// 检查器摘要用的有序分组。
    var groups: [(dimension: String, name: String, terms: [String])] {
        let known = ClassificationVocabulary.dimensions
            .filter { values[$0.id]?.isEmpty == false }
            .map { (dimension: $0.id, name: $0.name, terms: values[$0.id] ?? []) }
        let unknownIDs = values.keys.filter { ClassificationVocabulary.dimension($0) == nil }.sorted()
        return known + unknownIDs.map { (dimension: $0, name: $0, terms: values[$0] ?? []) }
    }

    /// 单行展示；用于卡片简介、导出 CSV、CLI。
    var displayText: String {
        groups.map { group in group.name + ":" + group.terms.joined(separator: "/") }.joined(separator: " · ")
    }

    /// 分类已写入的维度数，用于徽标或筛选计数。
    var dimensionCount: Int { groups.count }
}

extension MaterialRecord {
    mutating func mutateClassification(_ transform: (inout MaterialClassification) -> Void) {
        var value = classification ?? MaterialClassification()
        transform(&value)
        classification = value.isEmpty ? nil : value
    }

    var classificationDisplayText: String { classification?.displayText ?? "" }
}
