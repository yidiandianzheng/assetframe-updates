import Foundation

struct PendingImportListSnapshot {
    let filteredItems: [PendingImportItem]
    let visibleItems: [PendingImportItem]
    let visibleGroups: [PendingImportListGroup]

    init(
        items: [PendingImportItem],
        search: String,
        typeFilter: AssetType?,
        categoryFilter: AssetCategory?,
        sourceFilter: PendingImportSourceFilter,
        resolutionFilter: String,
        todayOnly: Bool,
        visibleLimit: Int,
        calendar: Calendar = .current
    ) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredItems = items.filter { item in
            (query.isEmpty || item.searchableText.localizedStandardContains(query)) &&
            (typeFilter == nil || item.suggestedType == typeFilter) &&
            (categoryFilter == nil || item.category == categoryFilter) &&
            sourceFilter.includes(item) &&
            (resolutionFilter == "全部清晰度" || item.resolutionLabel == resolutionFilter) &&
            (!todayOnly || calendar.isDateInToday(item.createdAt))
        }
        visibleItems = Array(filteredItems.prefix(visibleLimit))
        visibleGroups = PendingImportListGroup.make(from: visibleItems)
    }
}
