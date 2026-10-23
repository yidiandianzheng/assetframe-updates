import Foundation

/// Revision is a caller-owned contract covering values as well as membership/order.
struct GalleryContentIndex<Record: Identifiable & Equatable> {
    private(set) var byID: [Record.ID: Record] = [:]
    private(set) var orderedIDs: [Record.ID] = []
    private(set) var rebuildCount = 0
    private var revision: UInt64?

    mutating func update(_ records: [Record], revision nextRevision: UInt64?) -> Set<Record.ID> {
        if rebuildCount > 0, let nextRevision, revision == nextRevision { return [] }
        var next: [Record.ID: Record] = [:]
        var ids: [Record.ID] = []
        next.reserveCapacity(records.count)
        ids.reserveCapacity(records.count)
        var changed = Set<Record.ID>()
        for record in records where next[record.id] == nil {
            next[record.id] = record
            ids.append(record.id)
            if byID[record.id] != record { changed.insert(record.id) }
        }
        byID = next
        orderedIDs = ids
        revision = nextRevision
        rebuildCount += 1
        return changed
    }
}
