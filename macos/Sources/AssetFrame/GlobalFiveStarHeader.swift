import SwiftUI

struct GlobalFiveStarHeader: View {
    let scope: FiveStarScope
    let projectName: String
    let category: FiveStarAssetCategory?
    let isRefreshing: Bool
    @Binding var search: String
    @Binding var selectedType: AssetType?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在汇总资产")
            }
            Spacer()
            Menu(typeTitle, systemImage: "line.3.horizontal.decrease.circle") {
                Button("全部类型") { selectedType = nil }
                Divider()
                ForEach(availableTypes) { type in
                    Button(type.rawValue) { selectedType = type }
                }
            }
            .menuStyle(.borderlessButton)
            TextField("搜索名称、标签或来源项目", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($searchFocused)
                .accessibilityIdentifier("assetframe.workspace-search.global-five-star")
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(GraphiteTheme.toolbar)
        .onReceive(NotificationCenter.default.publisher(for: .focusWorkspaceSearch)) { _ in
            searchFocused = true
        }
    }

    private var subtitle: String {
        if scope == .currentProject {
            if let category { return "\(projectName)的五星\(category.rawValue)资产" }
            return "\(projectName)自己评出的五星，加上从全局引用的五星"
        }
        return "显示明确加入通用资产的内容，不限评分；同一文件按指纹去重"
    }

    private var typeTitle: String { selectedType?.rawValue ?? "全部类型" }

    private var availableTypes: [AssetType] {
        guard let category else { return AssetType.allCases }
        return AssetType.allCases.filter(category.includes)
    }

}
