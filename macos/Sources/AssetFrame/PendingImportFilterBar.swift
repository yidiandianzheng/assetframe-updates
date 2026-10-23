import SwiftUI

struct PendingImportFilterBar: View {
    @Binding var search: String
    @Binding var typeFilter: AssetType?
    @Binding var categoryFilter: AssetCategory?
    @Binding var sourceFilter: PendingImportSourceFilter
    @Binding var resolutionFilter: String
    @Binding var todayOnly: Bool

    let resolutionOptions: [String]
    let filteredCount: Int
    let isAllSelected: Bool
    let onToggleSelectAll: () -> Void

    private var hasActiveFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        typeFilter != nil || categoryFilter != nil ||
        sourceFilter != .all ||
        resolutionFilter != "全部清晰度" || todayOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(
                    isAllSelected ? "取消全选" : "全选",
                    systemImage: isAllSelected ? "checkmark.circle.fill" : "checkmark.circle",
                    action: onToggleSelectAll
                )
                .buttonStyle(.bordered)
                .disabled(filteredCount == 0)
                .fixedSize()
                .help(isAllSelected ? "取消选择当前筛选结果" : "选择当前筛选结果中的全部图片")

                Divider().frame(height: 24)

                Label("筛选", systemImage: "line.3.horizontal.decrease")
                    .font(.callout.bold())
                    .foregroundStyle(.secondary)
                    .fixedSize()

                TextField("搜索文件名或源图路径", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)

                HStack(spacing: 7) {
                    Text("类型").foregroundStyle(.secondary)
                    Picker("资产类型", selection: $typeFilter) {
                        Text("全部类型").tag(nil as AssetType?)
                        ForEach(AssetType.allCases) { type in
                            Text(type.rawValue).tag(type as AssetType?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 128)
                }
                .fixedSize()

                HStack(spacing: 7) {
                    Text("归类").foregroundStyle(.secondary)
                    Picker("资产归类", selection: $categoryFilter) {
                        Text("全部归类").tag(nil as AssetCategory?)
                        ForEach(AssetCategory.allCases) { category in
                            Text(category.rawValue).tag(category as AssetCategory?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 116)
                }
                .fixedSize()

                HStack(spacing: 7) {
                    Text("来源").foregroundStyle(.secondary)
                    Picker("生成来源", selection: $sourceFilter) {
                        ForEach(PendingImportSourceFilter.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 118)
                }
                .fixedSize()

                HStack(spacing: 7) {
                    Text("清晰度").foregroundStyle(.secondary)
                    Picker("清晰度", selection: $resolutionFilter) {
                        ForEach(resolutionOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 118)
                }
                .fixedSize()

                Toggle("仅看今日", isOn: $todayOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()

                if hasActiveFilters {
                    Button("重置", systemImage: "arrow.counterclockwise", action: resetFilters)
                        .buttonStyle(.borderless)
                }

                Spacer(minLength: 12)

                Text("当前 \(filteredCount) 项")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
        }
        .controlSize(.regular)
        .font(.callout)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func resetFilters() {
        search = ""
        typeFilter = nil
        categoryFilter = nil
        sourceFilter = .all
        resolutionFilter = "全部清晰度"
        todayOnly = false
    }
}
