import Foundation

/// Restores only user-edited fields, never source files or technical metadata.
struct MaterialUndoPatch: Codable, Hashable, Sendable {
    struct Conflict: LocalizedError { var errorDescription: String? { "素材字段已被后续操作改变，整批撤销未执行" } }
    enum Field: String, CaseIterable, Codable, Hashable, Sendable {
        case name, kind, tags, rating, note, color, classification, deleted
        case purpose, review, common
        /// 受控分类词表字段；与旧版 `classification`（assetType）分开，旧历史仍可解码。
        case categories
        func value(_ m: MaterialRecord) throws -> Data {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            switch self {
            case .name: return try e.encode(m.name)
            case .kind: return try e.encode(m.kind)
            case .tags: return try e.encode(m.tags)
            case .rating: return try e.encode(m.rating)
            case .note: return try e.encode(m.note)
            case .color: return try e.encode(m.colorLabel)
            case .classification: return try e.encode(m.assetType)
            case .categories: return try e.encode(m.classification)
            case .deleted: return try e.encode(m.deletedAt)
            case .purpose: return try e.encode(m.production?.purpose ?? "未指定")
            case .review: return try e.encode(m.production?.review ?? "待审核")
            case .common: return try e.encode(m.production?.isCommon ?? false)
            }
        }
        func set(_ data: Data, in m: inout MaterialRecord) throws {
            let d = JSONDecoder()
            switch self {
            case .name: m.name = try d.decode(String.self, from: data)
            case .kind: m.kind = try d.decode(MaterialKind.self, from: data)
            case .tags: m.tags = try d.decode([String].self, from: data)
            case .rating: m.rating = try d.decode(Int.self, from: data)
            case .note: m.note = try d.decode(String.self, from: data)
            case .color: m.colorLabel = try d.decode(String?.self, from: data)
            case .classification: m.assetType = try d.decode(AssetType?.self, from: data)
            case .categories: m.classification = try d.decode(MaterialClassification?.self, from: data)
            case .deleted: m.deletedAt = try d.decode(Date?.self, from: data)
            case .purpose, .review, .common:
                var p = m.production ?? MaterialProductionMetadata()
                if self == .purpose { p.purpose = try d.decode(String.self, from: data) }
                if self == .review { p.review = try d.decode(String.self, from: data) }
                if self == .common { p.isCommon = try d.decode(Bool.self, from: data) }
                m.production = p
            }
        }
    }
    struct Change: Codable, Hashable, Sendable { var id: String; var field: Field; var before: Data; var after: Data }
    struct History: Codable, Hashable, Identifiable, Sendable {
        var id = "history"
        var version = 1
        var undo: [MaterialUndoPatch] = []
        var redo: [MaterialUndoPatch] = []
        mutating func append(_ patch: MaterialUndoPatch) {
            redo.removeAll()
            guard patch.estimatedBytes <= 10 * 1024 * 1024 else { undo.removeAll(); return }
            undo.append(patch)
            while undo.count > 20 || undo.reduce(0, { $0 + $1.estimatedBytes }) > 10 * 1024 * 1024 { undo.removeFirst() }
        }
    }
    let changes: [Change]
    var taggingChanges: [MaterialTaggingUndo.Change]? = nil
    var isEmpty: Bool { changes.isEmpty && (taggingChanges ?? []).isEmpty }
    var estimatedBytes: Int { changes.reduce(0) { $0 + $1.before.count + $1.after.count + 128 } + (taggingChanges ?? []).reduce(0) { $0 + $1.bytes } }
    init(before: [MaterialRecord], after: [MaterialRecord]) throws {
        let originals = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var values: [Change] = []
        for record in after {
            guard let old = originals[record.id], old != record else { continue }
            for field in Field.allCases {
                let a = try field.value(old), b = try field.value(record)
                if a != b { values.append(Change(id: record.id, field: field, before: a, after: b)) }
            }
        }
        changes = values
    }
    private init(changes: [Change], taggingChanges: [MaterialTaggingUndo.Change]? = nil) { self.changes = changes; self.taggingChanges = taggingChanges }
    var inverse: Self { Self(changes: changes.map { Change(id: $0.id, field: $0.field, before: $0.after, after: $0.before) }, taggingChanges: taggingChanges?.map(\.inverse)) }
    func restore(in records: [MaterialRecord]) throws -> [MaterialRecord] {
        var result = records
        let positions = Dictionary(records.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for change in changes {
            guard let position = positions[change.id], try Self.equivalent(change.field.value(records[position]), change.after) else {
                throw Conflict()
            }
        }
        for change in changes { try change.field.set(change.before, in: &result[positions[change.id]!]) }
        return result
    }
    /// Old histories used unordered JSON objects. Compare their values, not dictionary serialization order.
    private static func equivalent(_ lhs: Data, _ rhs: Data) throws -> Bool {
        if lhs == rhs { return true }
        let a = try JSONSerialization.jsonObject(with: lhs, options: [.fragmentsAllowed])
        let b = try JSONSerialization.jsonObject(with: rhs, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed]) ==
            JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed])
    }
}
