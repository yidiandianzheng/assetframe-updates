import SwiftUI

struct FiveStarRatingDirectoryRow: View {
    let count: Int
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(
                isExpanded ? "收起 5 星分类" : "展开 5 星分类",
                systemImage: isExpanded ? "chevron.down" : "chevron.right",
                action: onToggleExpansion
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 23, height: 30)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")

            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("5 星")
                    Spacer()
                    Text(count, format: .number)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .padding(.trailing, 7)
                .frame(minHeight: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("5 星，\(count) 项")
            .help("显示当前项目全部五星资产")
        }
        .padding(.leading, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : .clear,
            in: .rect(cornerRadius: 6)
        )
    }
}
