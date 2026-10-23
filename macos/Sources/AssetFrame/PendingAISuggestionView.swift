import SwiftUI

struct PendingAISuggestionView: View {
    let suggestion: PendingAIAnalysisSuggestion
    let isApplied: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("AI建议：\(suggestion.assetType.rawValue) · \(suggestion.proposedName)", systemImage: "sparkles")
                    .lineLimit(1)
                Text(suggestion.normalizedConfidence, format: .percent.precision(.fractionLength(0)))
                if isApplied {
                    Label("已采纳", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("采纳", action: onApply)
                        .buttonStyle(.borderless)
                }
            }
            if !suggestion.summary.isEmpty {
                Text("判断依据：\(suggestion.summary)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !suggestion.styleTags.isEmpty {
                Text("标签：\(suggestion.styleTags.joined(separator: "、"))")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
