import Foundation

enum AssetSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部原图"
    case available = "原图正常"
    case missing = "源文件缺失"

    var id: Self { self }
}

enum AssetSortOption: String, CaseIterable, Identifiable, Sendable {
    case newest = "最近添加"
    case oldest = "最早添加"
    case usedNewest = "最近使用"
    case usedOldest = "最久未使用"
    case modifiedNewest = "最近修改"
    case modifiedOldest = "最早修改"
    case name = "名称 A–Z"
    case nameDescending = "名称 Z–A"
    case rating = "评分最高"
    case ratingLowest = "评分最低"
    case resolution = "分辨率最高"
    case resolutionLowest = "分辨率最低"

    var id: Self { self }

    var criterion: AssetSortCriterion {
        switch self {
        case .newest: .init(field: .createdAt, direction: .descending)
        case .oldest: .init(field: .createdAt, direction: .ascending)
        case .usedNewest: .init(field: .lastUsedAt, direction: .descending)
        case .usedOldest: .init(field: .lastUsedAt, direction: .ascending)
        case .modifiedNewest: .init(field: .sourceModifiedAt, direction: .descending)
        case .modifiedOldest: .init(field: .sourceModifiedAt, direction: .ascending)
        case .name: .init(field: .name, direction: .ascending)
        case .nameDescending: .init(field: .name, direction: .descending)
        case .rating: .init(field: .rating, direction: .descending)
        case .ratingLowest: .init(field: .rating, direction: .ascending)
        case .resolution: .init(field: .resolution, direction: .descending)
        case .resolutionLowest: .init(field: .resolution, direction: .ascending)
        }
    }
}

enum AssetSortField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case resolution = "分辨率"
    case fileSize = "文件大小"
    case rating = "评分"
    case createdAt = "添加日期"
    case lastUsedAt = "最近使用"
    case sourceCreatedAt = "创建日期"
    case sourceModifiedAt = "修改日期"
    case name = "名称"

    var id: Self { self }
}

enum AssetSortDirection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case ascending
    case descending

    var id: Self { self }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct AssetSortCriterion: Identifiable, Equatable, Hashable, Sendable {
    var field: AssetSortField
    var direction: AssetSortDirection

    var id: AssetSortField { field }

    var directionLabel: String {
        switch (field, direction) {
        case (.name, .ascending): "A → Z"
        case (.name, .descending): "Z → A"
        case (.createdAt, .ascending), (.lastUsedAt, .ascending), (.sourceCreatedAt, .ascending), (.sourceModifiedAt, .ascending): "早 → 晚"
        case (.createdAt, .descending), (.lastUsedAt, .descending), (.sourceCreatedAt, .descending), (.sourceModifiedAt, .descending): "晚 → 早"
        case (_, .ascending): "低 → 高"
        case (_, .descending): "高 → 低"
        }
    }
}

struct AssetSortConfiguration: Equatable, Hashable, Sendable {
    static let maximumCriteria = 5
    static let defaultCriteria = [
        AssetSortCriterion(field: .resolution, direction: .descending),
        AssetSortCriterion(field: .rating, direction: .descending),
        AssetSortCriterion(field: .createdAt, direction: .descending)
    ]

    private(set) var criteria: [AssetSortCriterion]

    init(criteria: [AssetSortCriterion] = Self.defaultCriteria) {
        var seen = Set<AssetSortField>()
        self.criteria = criteria.filter { seen.insert($0.field).inserted }.prefix(Self.maximumCriteria).map { $0 }
        if self.criteria.isEmpty {
            self.criteria = [Self.defaultCriteria[0]]
        }
    }

    init(_ option: AssetSortOption) {
        self.init(criteria: [option.criterion])
    }

    var cacheKey: String {
        criteria.map { "\($0.field.rawValue):\($0.direction.rawValue)" }.joined(separator: ",")
    }

    var availableFields: [AssetSortField] {
        let used = Set(criteria.map(\.field))
        return AssetSortField.allCases.filter { !used.contains($0) }
    }

    mutating func add(field: AssetSortField) {
        guard criteria.count < Self.maximumCriteria, !criteria.contains(where: { $0.field == field }) else { return }
        criteria.append(.init(field: field, direction: field == .name ? .ascending : .descending))
    }

    mutating func remove(at index: Int) {
        guard criteria.indices.contains(index), criteria.count > 1 else { return }
        criteria.remove(at: index)
    }

    mutating func move(from index: Int, offset: Int) {
        let destination = index + offset
        guard criteria.indices.contains(index), criteria.indices.contains(destination) else { return }
        criteria.swapAt(index, destination)
    }

    mutating func setField(_ field: AssetSortField, at index: Int) {
        guard criteria.indices.contains(index), !criteria.enumerated().contains(where: { $0.offset != index && $0.element.field == field }) else { return }
        criteria[index].field = field
        criteria[index].direction = field == .name ? .ascending : .descending
    }

    mutating func toggleDirection(at index: Int) {
        guard criteria.indices.contains(index) else { return }
        criteria[index].direction.toggle()
    }

    mutating func setDirection(_ direction: AssetSortDirection, at index: Int) {
        guard criteria.indices.contains(index) else { return }
        criteria[index].direction = direction
    }

    mutating func restoreDefault() {
        criteria = Self.defaultCriteria
    }

    // Compatibility shortcuts for call sites that intentionally request one
    // legacy sort. The gallery UI uses the multi-criterion initializer above.
    static var newest: Self { Self(.newest) }
    static var oldest: Self { Self(.oldest) }
    static var usedNewest: Self { Self(.usedNewest) }
    static var usedOldest: Self { Self(.usedOldest) }
    static var modifiedNewest: Self { Self(.modifiedNewest) }
    static var modifiedOldest: Self { Self(.modifiedOldest) }
    static var name: Self { Self(.name) }
    static var nameDescending: Self { Self(.nameDescending) }
    static var rating: Self { Self(.rating) }
    static var ratingLowest: Self { Self(.ratingLowest) }
    static var resolution: Self { Self(.resolution) }
    static var resolutionLowest: Self { Self(.resolutionLowest) }
}

struct AssetFilter: Equatable, Sendable {
    var type: AssetType?
    /// A decision predicate, rather than just one selected status. This keeps
    /// legacy views that need to hide discarded material expressible without
    /// requiring a second, divergent filter path.
    var decision: AssetDecisionFilter?
    var reuse: ReuseGrade?
    var tag: String?
    var fileExtensions: Set<String> = []
    var aspectRatios: Set<AssetAspectRatioFilterOption> = []
    var customAspectRatio: Double? = nil
    var minimumRating = 0
    var source = AssetSourceFilter.all
    var masterOnly = false

    var isActive: Bool {
        type != nil || decision != nil || reuse != nil || tag != nil || !fileExtensions.isEmpty || !aspectRatios.isEmpty || minimumRating > 0 || source != .all || masterOnly
    }

    mutating func reset() {
        self = AssetFilter()
    }

    func includes(_ asset: AssetItem) -> Bool {
        if let type, asset.type != type { return false }
        if let decision, !decision.includes(asset.decision) { return false }
        if let reuse, asset.reuse != reuse { return false }
        if let tag, !asset.normalizedTags.contains(tag) { return false }
        if !fileExtensions.isEmpty, !fileExtensions.contains(AssetFileFormat.normalizedExtension(for: asset)) { return false }
        if !aspectRatios.isEmpty {
            guard let ratio = AssetAspectRatioFilterOption.ratio(for: asset),
                  aspectRatios.contains(where: { $0.matches(ratio: ratio, customRatio: customAspectRatio) }) else { return false }
        }
        if asset.starRating < minimumRating { return false }
        if masterOnly, !asset.isMaster { return false }
        return switch source {
        case .all: true
        case .available: !asset.sourceMissing
        case .missing: asset.sourceMissing
        }
    }
}

enum AssetQuery {
    static func apply(
        to assets: [AssetItem],
        search: String,
        filter: AssetFilter,
        sort: AssetSortConfiguration
    ) -> [AssetItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = assets.filter { asset in
            guard filter.includes(asset) else { return false }
            guard !query.isEmpty else { return true }
            let searchable = [
                asset.id,
                asset.name,
                asset.originalFilename,
                asset.assetDescription,
                asset.note,
                asset.project,
                asset.episodes.joined(separator: " "),
                asset.normalizedTags.joined(separator: " "),
                asset.sourceURL ?? ""
            ].joined(separator: " ")
            return searchable.localizedStandardContains(query)
        }

        return filtered.sorted { lhs, rhs in
            for criterion in sort.criteria {
                let comparison = compare(lhs, rhs, field: criterion.field)
                guard comparison != .orderedSame else { continue }
                return criterion.direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return lhs.id < rhs.id
        }
    }

    private static func compare(_ lhs: AssetItem, _ rhs: AssetItem, field: AssetSortField) -> ComparisonResult {
        switch field {
        case .createdAt:
            return lhs.createdAt.compare(rhs.createdAt)
        case .lastUsedAt:
            return (lhs.lastUsedAt ?? .distantPast).compare(rhs.lastUsedAt ?? .distantPast)
        case .sourceCreatedAt:
            return (lhs.sourceCreatedAt ?? lhs.createdAt).compare(rhs.sourceCreatedAt ?? rhs.createdAt)
        case .sourceModifiedAt:
            return (lhs.sourceModifiedAt ?? lhs.createdAt).compare(rhs.sourceModifiedAt ?? rhs.createdAt)
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .rating:
            return compare(lhs.starRating, rhs.starRating)
        case .resolution:
            let left = Int64(lhs.pixelWidth ?? 0) * Int64(lhs.pixelHeight ?? 0)
            let right = Int64(rhs.pixelWidth ?? 0) * Int64(rhs.pixelHeight ?? 0)
            return compare(left, right)
        case .fileSize:
            return compare(lhs.sourceFileSize ?? 0, rhs.sourceFileSize ?? 0)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
