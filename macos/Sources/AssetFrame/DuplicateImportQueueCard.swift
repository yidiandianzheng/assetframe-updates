import SwiftUI

struct DuplicateImportQueueCard: View {
    let count: Int
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(GraphiteTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("待处理重复项 (count)")
                    .font(.system(size: 13, weight: .semibold))
                Text("导入已完成，可稍后集中处理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("查看", action: onReview)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(width: 350)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
    }
}
