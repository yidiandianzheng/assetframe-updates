import Foundation

enum LibraryAuditAnalyzer {
    static func analyze(
        assets: [AssetItem],
        variants: [AssetVariantRecord],
        scopeAssetIDs: Set<String>
    ) -> [LibraryAuditIssue] {
        let activeAssets = assets.filter {
            $0.deletedAt == nil && (scopeAssetIDs.isEmpty || scopeAssetIDs.contains($0.id))
        }
        let activeIDs = Set(activeAssets.map(\.id))
        var issues: [LibraryAuditIssue] = []

        for asset in activeAssets {
            if asset.sourceMissing {
                issues.append(issue(
                    kind: .sourceMissing,
                    severity: .blocking,
                    asset: asset,
                    detail: "当前原图及可用历史版本均无法定位，导出会失败。"
                ))
            }
            if asset.type == .unclassified {
                issues.append(issue(
                    kind: .unclassified,
                    severity: .warning,
                    asset: asset,
                    detail: "资产尚未归入人物、场景、道具或其他正式类型。"
                ))
            }
            if asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue(
                    kind: .emptyName,
                    severity: .blocking,
                    asset: asset,
                    detail: "资产名称为空，无法形成稳定的检索和交付名称。"
                ))
            }
            if asset.decision == .pending {
                issues.append(issue(
                    kind: .pendingReview,
                    severity: .review,
                    asset: asset,
                    detail: "这项资产尚未完成人工使用判断。"
                ))
            }
            if asset.prefers4KOutput && asset.resolutionLabel != "4K" {
                issues.append(issue(
                    kind: .fourKNotReady,
                    severity: .blocking,
                    asset: asset,
                    detail: "已指定4K交付目标，但当前最高可用原图只有\(asset.resolutionLabel)。"
                ))
            }
        }

        let duplicateGroups = Dictionary(grouping: activeAssets) { normalizedName($0.name) }
        for (name, matches) in duplicateGroups where !name.isEmpty && matches.count > 1 {
            let ids = matches.map(\.id).sorted()
            issues.append(LibraryAuditIssue(
                id: "duplicate-name|\(ids.joined(separator: ","))",
                kind: .duplicateName,
                severity: .review,
                title: "\(matches.first?.name ?? "同名资产") · \(matches.count)项同名",
                detail: "请确认它们是同一主体的不同形态，还是需要补充区分名称。",
                assetIDs: ids,
                variantID: nil
            ))
        }

        let scopedVariants = variants.filter { variant in
            scopeAssetIDs.isEmpty || !activeIDs.isDisjoint(with: variant.memberAssetIDs)
        }
        for variant in scopedVariants {
            if !variant.isLocked {
                issues.append(variantIssue(
                    kind: .unlockedVariant,
                    severity: .warning,
                    variant: variant,
                    detail: "形态仍处于待裁定状态，不能进入正式调用包。"
                ))
            }
            if variant.mainAssetID == nil {
                issues.append(variantIssue(
                    kind: .missingMainImage,
                    severity: .blocking,
                    variant: variant,
                    detail: "形态尚未指定唯一主图。"
                ))
            }
            if (variant.keyDifference ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(variantIssue(
                    kind: .missingKeyDifference,
                    severity: .warning,
                    variant: variant,
                    detail: "缺少一句可供生产人员识别的形态关键区别。"
                ))
            }
        }

        return issues.sorted {
            if severityOrder($0.severity) != severityOrder($1.severity) {
                return severityOrder($0.severity) < severityOrder($1.severity)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func issue(
        kind: LibraryAuditIssueKind,
        severity: LibraryAuditSeverity,
        asset: AssetItem,
        detail: String
    ) -> LibraryAuditIssue {
        LibraryAuditIssue(
            id: "asset|\(asset.id)|\(kind.rawValue)",
            kind: kind,
            severity: severity,
            title: asset.name.isEmpty ? asset.originalFilename : asset.name,
            detail: detail,
            assetIDs: [asset.id],
            variantID: nil
        )
    }

    private static func variantIssue(
        kind: LibraryAuditIssueKind,
        severity: LibraryAuditSeverity,
        variant: AssetVariantRecord,
        detail: String
    ) -> LibraryAuditIssue {
        LibraryAuditIssue(
            id: "variant|\(variant.id)|\(kind.rawValue)",
            kind: kind,
            severity: severity,
            title: variant.name,
            detail: detail,
            assetIDs: variant.memberAssetIDs,
            variantID: variant.id
        )
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacing(" ", with: "")
            .replacing("　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func severityOrder(_ severity: LibraryAuditSeverity) -> Int {
        switch severity {
        case .blocking: 0
        case .warning: 1
        case .review: 2
        }
    }
}
