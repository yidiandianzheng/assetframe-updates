import SwiftUI

struct SidebarQuickAccessSection: View {
    let selectedView: SavedView
    let counts: [SavedView: Int]
    let searchQuery: String
    let onSelect: (SavedView) -> Void

    private let navigationItems: [(SavedView, String, String)] = [
        (.unclassified, "tray", "查看尚未归类的项目资产"),
        (.untagged, "tag.slash", "查看尚未添加标签的项目资产"),
        (.recentlyUsed, "clock.arrow.circlepath", "按在软件中最近使用的时间排列"),
        (.random, "shuffle", "随机打乱当前项目的图片顺序；再点一次会重新洗牌"),
        (.trash, "trash", "查看可恢复的已删除资产")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("导航")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.top, 2)
                .padding(.bottom, 1)

            ForEach(visibleItems, id: \.0) { view, icon, help in
                row(view, icon: icon, help: help)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var visibleItems: [(SavedView, String, String)] {
        navigationItems.filter { view, _, _ in
            SidebarSearchMatcher.matches(searchQuery, candidates: [view.rawValue])
        }
    }

    private func row(_ view: SavedView, icon: String, help: String) -> some View {
        let isSelected = selectedView == view
        return Button { onSelect(view) } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(view.rawValue)
                Spacer()
                if view != .random {
                    Text(counts[view, default: 0], format: .number)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
