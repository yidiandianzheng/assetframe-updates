import Foundation

struct PendingImportListGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var isCodexGeneration: Bool
    var items: [PendingImportItem]

    static func make(from items: [PendingImportItem]) -> [PendingImportListGroup] {
        var groupOrder: [String] = []
        var groups: [String: PendingImportListGroup] = [:]

        for item in items {
            let key: String
            let title: String
            let subtitle: String
            let isCodexGeneration: Bool
            if let provenance = item.generationProvenance {
                key = "codex:\(provenance.batchID)"
                title = provenance.taskTitle
                subtitle = "\(provenance.batchID) · \(provenance.operation.displayName)"
                isCodexGeneration = true
            } else {
                key = "other"
                title = "其他待导入"
                subtitle = "扫描、拖入或手动选择"
                isCodexGeneration = false
            }

            if groups[key] == nil {
                groupOrder.append(key)
                groups[key] = PendingImportListGroup(
                    id: key,
                    title: title,
                    subtitle: subtitle,
                    isCodexGeneration: isCodexGeneration,
                    items: []
                )
            }
            groups[key]?.items.append(item)
        }
        return groupOrder.compactMap { groups[$0] }
    }
}
