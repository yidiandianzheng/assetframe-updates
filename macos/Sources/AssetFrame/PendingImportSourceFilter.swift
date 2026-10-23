import Foundation

enum PendingImportSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部来源"
    case codex = "Codex生成"
    case other = "其他来源"

    var id: Self { self }

    func includes(_ item: PendingImportItem) -> Bool {
        switch self {
        case .all: true
        case .codex: item.generationProvenance != nil
        case .other: item.generationProvenance == nil
        }
    }
}
