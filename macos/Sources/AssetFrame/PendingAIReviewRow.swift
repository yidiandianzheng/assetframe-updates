import SwiftUI

struct PendingAIReviewRow: View {
    let item: PendingImportItem
    let suggestion: PendingAIAnalysisSuggestion
    let onApply: (String, AssetType, [String]) -> Void
    let onIgnore: () -> Void

    @State private var proposedName: String
    @State private var assetType: AssetType
    @State private var tagsText: String

    init(
        item: PendingImportItem,
        suggestion: PendingAIAnalysisSuggestion,
        onApply: @escaping (String, AssetType, [String]) -> Void,
        onIgnore: @escaping () -> Void
    ) {
        self.item = item
        self.suggestion = suggestion
        self.onApply = onApply
        self.onIgnore = onIgnore
        _proposedName = State(initialValue: suggestion.proposedName)
        _assetType = State(initialValue: suggestion.assetType)
        _tagsText = State(initialValue: suggestion.normalizedTags.joined(separator: "、"))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AssetThumbnail(
                asset: item.previewAsset,
                size: CGSize(width: 120, height: 88),
                contentMode: .fit
            )
            .accessibilityLabel("待确认 AI 建议图片，\(item.originalFilename)")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.originalFilename)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(suggestion.normalizedConfidence, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                TextField("建议名称", text: $proposedName)
                Picker("资产类型", selection: $assetType) {
                    ForEach(AssetType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                TextField("标签，用逗号或顿号分隔", text: $tagsText)
                if !suggestion.summary.isEmpty {
                    Text("判断依据：\(suggestion.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let modelName = suggestion.modelName {
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("忽略", action: onIgnore)
                    Button("采纳修改", action: apply)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func apply() {
        let tags = tagsText
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onApply(proposedName, assetType, tags)
    }
}
