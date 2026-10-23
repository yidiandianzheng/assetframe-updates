import Combine
import Foundation

struct SavedFilterPreset: Identifiable, Codable, Equatable, Sendable {
    struct SortRule: Codable, Equatable, Sendable {
        let field: String
        let direction: String
    }

    let id: UUID
    var name: String
    var type: String?
    var decision: String?
    var reuse: String?
    var tag: String?
    var fileExtensions: [String]
    var aspectRatios: [String]
    var customAspectRatio: Double?
    var minimumRating: Int
    var source: String
    var masterOnly: Bool
    var sortRules: [SortRule]

    init(name: String, filter: AssetFilter, sort: AssetSortConfiguration) {
        id = UUID()
        self.name = name
        type = filter.type?.rawValue
        decision = filter.decision?.cacheKey
        reuse = filter.reuse?.rawValue
        tag = filter.tag
        fileExtensions = filter.fileExtensions.sorted()
        aspectRatios = filter.aspectRatios.map(\.rawValue).sorted()
        customAspectRatio = filter.customAspectRatio
        minimumRating = filter.minimumRating
        source = filter.source.rawValue
        masterOnly = filter.masterOnly
        sortRules = sort.criteria.map { SortRule(field: $0.field.rawValue, direction: $0.direction.rawValue) }
    }

    var filter: AssetFilter {
        var value = AssetFilter()
        value.type = type.flatMap(AssetType.init(rawValue:))
        value.decision = decision.flatMap(Self.decisionFilter)
        value.reuse = reuse.flatMap(ReuseGrade.init(rawValue:))
        value.tag = tag
        value.fileExtensions = Set(fileExtensions)
        value.aspectRatios = Set(aspectRatios.compactMap(AssetAspectRatioFilterOption.init(rawValue:)))
        value.customAspectRatio = customAspectRatio
        value.minimumRating = minimumRating
        value.source = AssetSourceFilter(rawValue: source) ?? .all
        value.masterOnly = masterOnly
        return value
    }

    var sort: AssetSortConfiguration {
        let criteria = sortRules.compactMap { rule -> AssetSortCriterion? in
            guard let field = AssetSortField(rawValue: rule.field),
                  let direction = AssetSortDirection(rawValue: rule.direction) else { return nil }
            return AssetSortCriterion(field: field, direction: direction)
        }
        return AssetSortConfiguration(criteria: criteria)
    }

    private static func decisionFilter(_ value: String) -> AssetDecisionFilter? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let decision = UserDecision(rawValue: parts[1]) else { return nil }
        return parts[0] == "excluding" ? .excluding(decision) : .only(decision)
    }
}

@MainActor
final class SavedFilterPresetStore: ObservableObject {
    @Published private(set) var presets: [SavedFilterPreset] = []

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "assetSavedFilterPresetsV1") {
        self.defaults = defaults
        self.key = key
        load()
    }

    func add(name: String, filter: AssetFilter, sort: AssetSortConfiguration) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        presets.removeAll { $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame }
        presets.append(SavedFilterPreset(name: cleaned, filter: filter, sort: sort))
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedFilterPreset].self, from: data) else { return }
        presets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }
}
