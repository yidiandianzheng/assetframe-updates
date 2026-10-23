import SwiftUI

struct AssetFilterBar: View {
    @StateObject private var presetStore = SavedFilterPresetStore()
    @State private var showsSavePreset = false
    @State private var presetName = ""
    @Binding var filter: AssetFilter
    @Binding var sort: AssetSortConfiguration
    let tags: [String]
    let formatCounts: [String: Int]
    let shapeCounts: [AssetAspectRatioFilterOption: Int]
    let resultCount: Int

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    typeMenu
                    ShapeFilterButton(filter: $filter, counts: shapeCounts)
                    FileFormatFilterButton(selectedFormats: $filter.fileExtensions, counts: formatCounts)
                    decisionMenu
                    tagMenu
                    ratingMenu
                    reuseMenu
                    sourceMenu
                    moreMenu
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .layoutPriority(1)

            Divider()
                .frame(height: 20)

            AssetMultiSortMenu(sort: $sort)
                .fixedSize()

            savedFilterMenu
                .fixedSize()

            Text("\(resultCount) 项")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            Button("清除筛选", systemImage: "xmark.circle", action: reset)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!filter.isActive)
                .help(filter.isActive ? "清除全部筛选" : "当前没有启用筛选")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(GraphiteTheme.toolbar)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("资产筛选工具")
        .alert("保存筛选组合", isPresented: $showsSavePreset) {
            TextField("例如：人物 + 4 星以上", text: $presetName)
            Button("取消", role: .cancel) { presetName = "" }
            Button("保存") {
                presetStore.add(name: presetName, filter: filter, sort: sort)
                presetName = ""
            }
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("保存当前筛选与多级排序；只写入本机设置，不修改资产数据库。")
        }
    }

    private var savedFilterMenu: some View {
        Menu("筛选组合", systemImage: "bookmark") {
            if presetStore.presets.isEmpty {
                Text("还没有已保存组合")
            } else {
                ForEach(presetStore.presets) { preset in
                    Button(preset.name) {
                        filter = preset.filter
                        sort = preset.sort
                    }
                }
                Divider()
                Menu("删除组合", systemImage: "trash") {
                    ForEach(presetStore.presets) { preset in
                        Button(preset.name, role: .destructive) { presetStore.remove(preset.id) }
                    }
                }
            }
            Divider()
            Button("保存当前组合…", systemImage: "plus") {
                presetName = ""
                showsSavePreset = true
            }
        }
        .help("保存并恢复常用筛选与排序")
    }

    private var typeMenu: some View {
        Menu {
            Button("全部类型") { filter.type = nil }
            Divider()
            ForEach(AssetType.allCases) { type in
                selectableButton(type.rawValue, selected: filter.type == type) {
                    filter.type = type
                }
            }
        } label: {
            dimensionLabel(
                filter.type?.rawValue ?? "类型",
                systemImage: "square.grid.2x2",
                active: filter.type != nil
            )
        }
        .help("按人物、场景、道具等资产类型筛选")
    }

    private var decisionMenu: some View {
        Menu {
            Button("全部审核状态") { filter.decision = nil }
            Divider()
            ForEach(UserDecision.allCases) { decision in
                selectableButton(decision.displayName, selected: filter.decision == .only(decision)) {
                    filter.decision = .only(decision)
                }
            }
            Divider()
            selectableButton("不看废片", selected: filter.decision == .excluding(.rejected)) {
                filter.decision = .excluding(.rejected)
            }
        } label: {
            dimensionLabel(
                filter.decision?.displayName ?? "审核",
                systemImage: "checkmark.circle",
                active: filter.decision != nil
            )
        }
        .help("按使用、备用、废片状态筛选")
    }

    private var tagMenu: some View {
        Menu {
            Button("全部标签") { filter.tag = nil }
            if !tags.isEmpty { Divider() }
            ForEach(tags, id: \.self) { tag in
                selectableButton(tag, selected: filter.tag == tag) {
                    filter.tag = tag
                }
            }
        } label: {
            dimensionLabel(
                filter.tag ?? "标签",
                systemImage: "tag",
                active: filter.tag != nil
            )
        }
        .disabled(tags.isEmpty)
        .help(tags.isEmpty ? "当前项目还没有标签" : "按资产标签筛选")
    }

    private var ratingMenu: some View {
        Menu {
            Button("全部评分") { filter.minimumRating = 0 }
            Divider()
            ForEach((1...5).reversed(), id: \.self) { value in
                selectableButton("\(value) 星及以上", selected: filter.minimumRating == value) {
                    filter.minimumRating = value
                }
            }
        } label: {
            dimensionLabel(
                filter.minimumRating == 0 ? "评分" : "\(filter.minimumRating) 星+",
                systemImage: "star",
                active: filter.minimumRating > 0
            )
        }
        .help("按最低星级筛选")
    }

    private var reuseMenu: some View {
        Menu {
            Button("全部复用等级") { filter.reuse = nil }
            Divider()
            ForEach(ReuseGrade.allCases) { reuse in
                selectableButton(reuse.rawValue, selected: filter.reuse == reuse) {
                    filter.reuse = reuse
                }
            }
        } label: {
            dimensionLabel(
                filter.reuse?.rawValue ?? "复用",
                systemImage: "arrow.triangle.2.circlepath",
                active: filter.reuse != nil
            )
        }
        .help("按复用等级筛选")
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(AssetSourceFilter.allCases) { source in
                selectableButton(source.rawValue, selected: filter.source == source) {
                    filter.source = source
                }
            }
        } label: {
            dimensionLabel(
                filter.source == .all ? "文件" : filter.source.rawValue,
                systemImage: "externaldrive",
                active: filter.source != .all
            )
        }
        .help("按原图正常或缺失状态筛选")
    }

    private var moreMenu: some View {
        Menu {
            Toggle("仅看通用资产", systemImage: "sparkles.rectangle.stack", isOn: $filter.masterOnly)
            if filter.isActive {
                Divider()
                Button("清除全部筛选", systemImage: "xmark.circle", action: reset)
            }
        } label: {
            dimensionLabel(
                filter.masterOnly ? "通用资产" : "更多",
                systemImage: "plus",
                active: filter.masterOnly
            )
        }
        .help("更多筛选条件")
    }

    private func dimensionLabel(_ title: String, systemImage: String, active: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }

    private func selectableButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func reset() {
        filter.reset()
    }
}
