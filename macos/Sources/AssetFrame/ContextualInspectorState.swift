import Foundation

enum InspectorItemKind: String, Equatable, Sendable {
    case formal
    case pending
    case globalFiveStar
    case material
}

struct InspectorSelectionRecord: Equatable, Sendable {
    let id: String
    let kind: InspectorItemKind
    let fileSize: Int64?
    let sourceMissing: Bool
}

struct InspectorScopeSummary: Equatable, Sendable {
    let title: String
    let itemCount: Int
    let totalFileSize: Int64
    let missingSourceCount: Int
    let queryIsActive: Bool
}

struct InspectorBatchSummary: Equatable, Sendable {
    let formalIDs: Set<String>
    let pendingIDs: Set<String>
    let globalFiveStarIDs: Set<String>
    let materialIDs: Set<String>
    let totalFileSize: Int64
    let missingSourceCount: Int

    init(
        formalIDs: Set<String>,
        pendingIDs: Set<String>,
        globalFiveStarIDs: Set<String> = [],
        materialIDs: Set<String> = [],
        totalFileSize: Int64,
        missingSourceCount: Int
    ) {
        self.formalIDs = formalIDs
        self.pendingIDs = pendingIDs
        self.globalFiveStarIDs = globalFiveStarIDs
        self.materialIDs = materialIDs
        self.totalFileSize = totalFileSize
        self.missingSourceCount = missingSourceCount
    }

    var itemCount: Int {
        formalIDs.count + pendingIDs.count + globalFiveStarIDs.count + materialIDs.count
    }
}

enum ContextualInspectorMode: Equatable, Sendable {
    case scope(InspectorScopeSummary)
    case singleFormal(String)
    case singlePending(String)
    case singleGlobalFiveStar(String)
    case singleMaterial(String)
    case multiple(InspectorBatchSummary)
}

enum ContextualInspectorResolver {
    static func resolve(
        selectedIDs: Set<String>,
        records: [InspectorSelectionRecord],
        scope: InspectorScopeSummary
    ) -> ContextualInspectorMode {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let selectedRecords = selectedIDs.compactMap { recordsByID[$0] }

        guard !selectedRecords.isEmpty else { return .scope(scope) }
        if selectedRecords.count == 1, let record = selectedRecords.first {
            switch record.kind {
            case .formal: return .singleFormal(record.id)
            case .pending: return .singlePending(record.id)
            case .globalFiveStar: return .singleGlobalFiveStar(record.id)
            case .material: return .singleMaterial(record.id)
            }
        }

        let formalIDs = Set(selectedRecords.lazy.filter { $0.kind == .formal }.map(\.id))
        let pendingIDs = Set(selectedRecords.lazy.filter { $0.kind == .pending }.map(\.id))
        let globalFiveStarIDs = Set(selectedRecords.lazy.filter { $0.kind == .globalFiveStar }.map(\.id))
        let materialIDs = Set(selectedRecords.lazy.filter { $0.kind == .material }.map(\.id))
        let totalFileSize = selectedRecords.reduce(Int64(0)) { partial, record in
            partial + max(0, record.fileSize ?? 0)
        }
        return .multiple(InspectorBatchSummary(
            formalIDs: formalIDs,
            pendingIDs: pendingIDs,
            globalFiveStarIDs: globalFiveStarIDs,
            materialIDs: materialIDs,
            totalFileSize: totalFileSize,
            missingSourceCount: selectedRecords.lazy.filter(\.sourceMissing).count
        ))
    }
}
