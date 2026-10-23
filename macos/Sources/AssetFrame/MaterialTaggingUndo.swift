import Foundation

/// Per-row metadata patches keep candidate decisions and vocabulary edits in the same undo transaction.
enum MaterialTaggingUndo {
    enum Section: String, Codable, Sendable { case terms, sources, bindings, proposals, jobs }
    struct Change: Codable, Hashable, Sendable {
        var section: Section
        var id: String
        var before: Data?
        var after: Data?
        var inverse: Self { .init(section: section, id: id, before: after, after: before) }
        var bytes: Int { (before?.count ?? 0) + (after?.count ?? 0) + 128 }
    }
    private static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func diff<T: Codable & Hashable & Identifiable & Sendable>(_ a: [T], _ b: [T], section: Section) throws -> [Change] where T.ID == String {
        let old = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(b.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try Set(old.keys).union(new.keys).sorted().compactMap { id in
            guard old[id] != new[id] else { return nil }
            return Change(section: section, id: id, before: try old[id].map(data), after: try new[id].map(data))
        }
    }
    static func changes(before: MaterialTaggingState, after: MaterialTaggingState) throws -> [Change] {
        try diff(before.terms, after.terms, section: .terms) + diff(before.sources, after.sources, section: .sources) +
        diff(before.bindings, after.bindings, section: .bindings) + diff(before.proposals, after.proposals, section: .proposals) +
        diff(before.jobs, after.jobs, section: .jobs)
    }
    private static func restore<T: Codable & Hashable & Identifiable & Sendable>(_ change: Change, in values: inout [T]) throws where T.ID == String {
        let current = try values.first { $0.id == change.id }.map(data)
        guard current == change.after else { throw MaterialUndoPatch.Conflict() }
        values.removeAll { $0.id == change.id }
        if let before = change.before { values.append(try JSONDecoder().decode(T.self, from: before)) }
    }
    static func restore(_ changes: [Change], in state: MaterialTaggingState) throws -> MaterialTaggingState {
        var result = state
        for change in changes {
            switch change.section {
            case .terms: try restore(change, in: &result.terms)
            case .sources: try restore(change, in: &result.sources)
            case .bindings: try restore(change, in: &result.bindings)
            case .proposals: try restore(change, in: &result.proposals)
            case .jobs: try restore(change, in: &result.jobs)
            }
        }
        return result
    }
}
