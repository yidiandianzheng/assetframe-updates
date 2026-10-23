import SwiftUI

struct AttentionSummary: Equatable, Sendable {
    let unreviewedCount: Int
    let unclassifiedCount: Int
    let missingSourceCount: Int
    let exportBlockingCount: Int

    var totalActionCount: Int {
        unclassifiedCount + missingSourceCount + exportBlockingCount
    }

    static func derive(assets: [AssetItem], pendingImports: [PendingImportItem], exportIssues: [ExportHealthIssue]) -> Self {
        Self(
            unreviewedCount: pendingImports.count { $0.effectiveReviewStatus == .unreviewed },
            unclassifiedCount: assets.count { $0.type == .unclassified || $0.category == .pending },
            missingSourceCount: assets.count(where: \.sourceMissing),
            exportBlockingCount: exportIssues.count { $0.severity == .blocking }
        )
    }
}

struct AttentionCenterView: View {
    let summary: AttentionSummary
    let onOpenUnclassified: () -> Void
    let onOpenMissingSources: () -> Void
    let onOpenExportLibrary: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待处理")
                        .font(.largeTitle.bold())
                    Text(summary.totalActionCount == 0 ? "当前没有阻塞日常流程的事项。" : "只汇总需要你采取行动的内容，不展示无关统计。")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    attentionCard(
                        title: "待分类",
                        count: summary.unclassifiedCount,
                        detail: "类型未确定或仍在待整理范围",
                        systemImage: "questionmark.folder",
                        actionTitle: "去分类",
                        action: onOpenUnclassified
                    )
                    attentionCard(
                        title: "源文件异常",
                        count: summary.missingSourceCount,
                        detail: "原文件已移动、离线或不可访问",
                        systemImage: "externaldrive.badge.exclamationmark",
                        actionTitle: "检查文件",
                        action: onOpenMissingSources
                    )
                    attentionCard(
                        title: "导出阻塞",
                        count: summary.exportBlockingCount,
                        detail: "命名、分类、原图或交付规则未通过",
                        systemImage: "shippingbox.and.arrow.backward",
                        actionTitle: "检查导出库",
                        action: onOpenExportLibrary
                    )
                }

                if summary.totalActionCount == 0 {
                    ContentUnavailableView(
                        "流程已清空",
                        systemImage: "checkmark.circle.fill",
                        description: Text("可以继续收集素材，或直接进入导出库完成交付。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(24)
        }
        .background(GraphiteTheme.canvas)
    }

    private func attentionCard(
        title: String,
        count: Int,
        detail: String,
        systemImage: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Text("\(count)")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(count == 0 ? .secondary : Color.orange)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(count == 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(count) 项，\(detail)")
    }
}
