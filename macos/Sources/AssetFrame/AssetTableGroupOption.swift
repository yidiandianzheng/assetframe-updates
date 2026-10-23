import Foundation

enum AssetTableGroupOption: String, CaseIterable, Identifiable, Sendable {
    case none = "不分组"
    case type = "按资产类型"
    case decision = "按审核状态"
    case reuse = "按复用等级"
    case sourceStatus = "按源文件状态"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .none: "rectangle.3.group"
        case .type: "square.grid.2x2"
        case .decision: "checkmark.circle"
        case .reuse: "arrow.triangle.2.circlepath"
        case .sourceStatus: "externaldrive"
        }
    }

    func value(for asset: AssetItem) -> String {
        switch self {
        case .none: "全部资产"
        case .type: asset.type.rawValue
        case .decision: asset.decision.rawValue
        case .reuse: "\(asset.reuse.rawValue) 级"
        case .sourceStatus: asset.sourceMissing ? "源文件缺失" : "源文件正常"
        }
    }

    func sections(from assets: [AssetItem]) -> [AssetTableSection] {
        guard self != .none else {
            return [AssetTableSection(id: rawValue, title: "全部资产", assets: assets)]
        }

        return Dictionary(grouping: assets) { value(for: $0) }
            .map { AssetTableSection(id: $0.key, title: $0.key, assets: $0.value) }
            .sorted {
                let left = order(of: $0.title)
                let right = order(of: $1.title)
                return left == right
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : left < right
            }
    }

    private func order(of title: String) -> Int {
        switch self {
        case .none: 0
        case .type: AssetType.allCases.firstIndex(where: { $0.rawValue == title }) ?? .max
        case .decision: UserDecision.allCases.firstIndex(where: { $0.rawValue == title }) ?? .max
        case .reuse: ReuseGrade.allCases.firstIndex(where: { "\($0.rawValue) 级" == title }) ?? .max
        case .sourceStatus: title == "源文件正常" ? 0 : 1
        }
    }
}
