import SwiftUI

struct CurrentProjectOverviewRow: View {
    let assetCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    let showProjectAssets: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggleExpansion) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起当前项目的星级分类" : "展开当前项目的星级分类")

            Button(action: showProjectAssets) {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text("当前项目资产")
                    Spacer()
                    Text(assetCount, format: .number)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .padding(.trailing, 7)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("显示当前项目的全部资产")
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityElement(children: .contain)
    }
}
