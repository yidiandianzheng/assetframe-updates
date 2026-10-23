import Foundation

@main
struct SavedFilterPresetSelfTest {
    @MainActor
    static func main() {
        var filter = AssetFilter()
        filter.type = .person
        filter.decision = .only(.confirmed)
        filter.tag = "主角"
        filter.minimumRating = 4
        filter.source = .available
        let sort = AssetSortConfiguration(criteria: [
            .init(field: .rating, direction: .descending),
            .init(field: .name, direction: .ascending)
        ])

        let preset = SavedFilterPreset(name: "人物 4 星已确认", filter: filter, sort: sort)
        precondition(preset.filter == filter)
        precondition(preset.sort == sort)

        let suiteName = "AssetFrame.SavedFilterPresetSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SavedFilterPresetStore(defaults: defaults, key: "presets")
        store.add(name: preset.name, filter: filter, sort: sort)
        precondition(store.presets.count == 1)
        store.add(name: preset.name, filter: AssetFilter(), sort: .newest)
        precondition(store.presets.count == 1, "同名保存应替换而不是制造重复入口")
        let restored = SavedFilterPresetStore(defaults: defaults, key: "presets")
        precondition(restored.presets.count == 1)

        precondition(WorkspaceDestination.allCases.map(\.displayName) == ["资产库", "素材总库", "导出库", "回收站"])
        precondition(WorkspaceDestination.exportLibrary.savedView == .exportLibrary)

        print("SavedFilterPresetSelfTest passed")
    }
}

