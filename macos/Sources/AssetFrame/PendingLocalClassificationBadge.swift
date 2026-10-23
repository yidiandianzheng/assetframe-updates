import SwiftUI

struct PendingLocalClassificationBadge: View {
    let item: PendingImportItem

    var body: some View {
        if item.localVisionAnalyzedAt != nil {
            Label {
                if let type = item.localVisionType,
                   let confidence = item.localVisionConfidence,
                   confidence >= LocalImageClassifier.adoptionThreshold {
                    HStack(spacing: 4) {
                        Text("本机识图参考：\(type.rawValue)")
                        Text(confidence, format: .percent.precision(.fractionLength(0)))
                    }
                } else {
                    Text("本机识图：置信度不足，保留原分类")
                }
            } icon: {
                Image(systemName: "brain.head.profile")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        guard let type = item.localVisionType,
              let confidence = item.localVisionConfidence,
              confidence >= LocalImageClassifier.adoptionThreshold else {
            return "本机识图置信度不足，保留原分类"
        }
        return "本机识图参考，\(type.rawValue)，置信度\(Int((confidence * 100).rounded()))百分比"
    }
}
