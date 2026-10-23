import Foundation

enum SidebarQuickAccessCodec {
    static func decode(_ rawValue: String) -> [SidebarQuickAccessItem] {
        guard let data = rawValue.data(using: .utf8),
              let items = try? JSONDecoder().decode([SidebarQuickAccessItem].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func encode(_ items: [SidebarQuickAccessItem]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    static func toggling(_ item: SidebarQuickAccessItem, in items: [SidebarQuickAccessItem]) -> [SidebarQuickAccessItem] {
        if items.contains(item) {
            return items.filter { $0 != item }
        }
        return items + [item]
    }

    static func moving(_ itemID: String, by offset: Int, in items: [SidebarQuickAccessItem]) -> [SidebarQuickAccessItem] {
        guard let sourceIndex = items.firstIndex(where: { $0.id == itemID }) else { return items }
        let destinationIndex = sourceIndex + offset
        guard items.indices.contains(destinationIndex) else { return items }
        var result = items
        result.swapAt(sourceIndex, destinationIndex)
        return result
    }

    static func moving(_ itemID: String, before destinationID: String, in items: [SidebarQuickAccessItem]) -> [SidebarQuickAccessItem] {
        guard itemID != destinationID,
              let sourceIndex = items.firstIndex(where: { $0.id == itemID }),
              items.contains(where: { $0.id == destinationID }) else { return items }
        var result = items
        let item = result.remove(at: sourceIndex)
        guard let destinationIndex = result.firstIndex(where: { $0.id == destinationID }) else { return items }
        result.insert(item, at: destinationIndex)
        return result
    }

    static func replacingRenamedPath(
        projectID: String,
        sourceID: String,
        oldPath: String,
        newPath: String,
        in items: [SidebarQuickAccessItem]
    ) -> [SidebarQuickAccessItem] {
        items.map { item in
            guard item.projectID == projectID,
                  item.sourceID == sourceID,
                  (item.relativePath == oldPath || item.relativePath.hasPrefix(oldPath + "/")) else {
                return item
            }
            var copy = item
            copy.relativePath = newPath + String(item.relativePath.dropFirst(oldPath.count))
            return copy
        }
    }
}
