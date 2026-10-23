import SwiftUI

struct LibraryAuditIssueRow: View {
    let issue: LibraryAuditIssue
    let suggestion: LibraryAuditSuggestion?
    let isApplied: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(issue.severity.rawValue, systemImage: severityIcon)
                    .foregroundStyle(severityColor)
                Text(issue.kind.rawValue)
                    .foregroundStyle(.secondary)
                Text(issue.title)
                    .bold()
                    .lineLimit(1)
                Spacer()
            }
            Text(issue.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let suggestion {
                Divider()
                Label(suggestion.explanation, systemImage: "sparkles")
                    .font(.callout)
                if !proposalSummary(suggestion).isEmpty {
                    Text("建议字段：\(proposalSummary(suggestion))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(suggestion.normalizedConfidence, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isApplied {
                        Label("已采纳安全字段", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if suggestion.hasEditableChange {
                        Button("采纳文字字段", systemImage: "checkmark", action: onApply)
                            .buttonStyle(.bordered)
                    } else {
                        Text("仅供人工处理参考")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var severityIcon: String {
        switch issue.severity {
        case .blocking: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .review: "questionmark.circle.fill"
        }
    }

    private var severityColor: Color {
        switch issue.severity {
        case .blocking: .red
        case .warning: .orange
        case .review: .secondary
        }
    }

    private func proposalSummary(_ suggestion: LibraryAuditSuggestion) -> String {
        var values: [String] = []
        if let proposedName = suggestion.proposedName { values.append("名称“\(proposedName)”") }
        if let assetType = suggestion.assetType { values.append("类型“\(assetType.rawValue)”") }
        if !suggestion.tags.isEmpty { values.append("标签“\(suggestion.tags.joined(separator: "、"))”") }
        if let summary = suggestion.summary { values.append("说明“\(summary)”") }
        return values.joined(separator: "；")
    }
}
