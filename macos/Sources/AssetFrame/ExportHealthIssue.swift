import Foundation

enum ExportHealthSeverity: String, Codable, Sendable {
    case blocking
    case warning
}

enum ExportHealthIssueKind: String, Codable, CaseIterable, Sendable {
    case missingSource
    case emptyName
    case unclassified
    case duplicateContent
    case unconfirmedCandidate
    case lowResolution

    var displayName: String {
        switch self {
        case .missingSource: "缺少原图"
        case .emptyName: "未命名"
        case .unclassified: "未分类"
        case .duplicateContent: "重复内容"
        case .unconfirmedCandidate: "非正式候选"
        case .lowResolution: "低分辨率"
        }
    }

    var systemImage: String {
        switch self {
        case .missingSource: "externaldrive.badge.exclamationmark"
        case .emptyName: "character.cursor.ibeam"
        case .unclassified: "questionmark.folder"
        case .duplicateContent: "square.on.square"
        case .unconfirmedCandidate: "clock.badge.questionmark"
        case .lowResolution: "rectangle.compress.vertical"
        }
    }
}

struct ExportHealthIssue: Identifiable, Equatable, Sendable {
    let kind: ExportHealthIssueKind
    let severity: ExportHealthSeverity
    let assetID: String
    let assetName: String
    let message: String

    var id: String { "\(kind.rawValue)|\(assetID)" }
}

enum ExportHealthAnalyzer {
    static let lowResolutionPixelThreshold: Int64 = 1_000_000

    static func analyze(assets: [AssetItem], exportNames: [String: String]) -> [ExportHealthIssue] {
        let fingerprints = Dictionary(grouping: assets.filter { !$0.fingerprint.isEmpty }, by: \.fingerprint)
        let duplicateIDs = Set(fingerprints.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })

        return assets.flatMap { asset -> [ExportHealthIssue] in
            var issues: [ExportHealthIssue] = []
            if bestAvailableSource(for: asset) == nil {
                issues.append(issue(.missingSource, .blocking, asset, "所有原图版本均不可用"))
            }
            if (exportNames[asset.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue(.emptyName, .blocking, asset, "导出名称为空"))
            }
            if asset.type == .unclassified || asset.category == .pending {
                issues.append(issue(.unclassified, .blocking, asset, "尚未完成资产分类"))
            }
            if duplicateIDs.contains(asset.id) {
                issues.append(issue(.duplicateContent, .warning, asset, "导出库中存在相同指纹内容"))
            }
            if asset.decision == .pending || asset.generationProvenance != nil && asset.decision != .confirmed {
                issues.append(issue(.unconfirmedCandidate, .warning, asset, "仍是待确认候选，尚未明确用于交付"))
            }
            let pixelCount = Int64(asset.pixelWidth ?? 0) * Int64(asset.pixelHeight ?? 0)
            if pixelCount > 0 && pixelCount < lowResolutionPixelThreshold {
                issues.append(issue(.lowResolution, .warning, asset, "分辨率低于 100 万像素"))
            }
            return issues
        }
    }

    private static func issue(
        _ kind: ExportHealthIssueKind,
        _ severity: ExportHealthSeverity,
        _ asset: AssetItem,
        _ message: String
    ) -> ExportHealthIssue {
        ExportHealthIssue(kind: kind, severity: severity, assetID: asset.id, assetName: asset.name, message: message)
    }

    private static func bestAvailableSource(for asset: AssetItem) -> AssetSourceVersion? {
        asset.allSourceVersions
            .filter { !$0.path.isEmpty && FileManager.default.fileExists(atPath: $0.path) }
            .max { lhs, rhs in
                if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount < rhs.pixelCount }
                return (lhs.fileSize ?? 0) < (rhs.fileSize ?? 0)
            }
    }
}
