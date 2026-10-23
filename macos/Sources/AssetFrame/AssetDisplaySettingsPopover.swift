import SwiftUI

struct AssetDisplaySettingsPopover: View {
    @Binding var layoutMode: AssetGalleryLayoutMode
    @Binding var sort: AssetSortConfiguration
    @Binding var thumbnailWidth: Double
    @Binding var showsName: Bool
    @Binding var showsDescription: Bool
    @Binding var showsSecondaryInfo: Bool
    @Binding var secondaryInfoMode: AssetSecondaryInfoMode
    @Binding var showsExtension: Bool
    @Binding var showsTags: Bool
    @Binding var showsTagCount: Bool
    @Binding var showsRating: Bool
    @Binding var folderScope: LocalFolderScope
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    let folderScopeEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(GraphiteTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(GraphiteTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("画册显示设置")
                        .font(.headline)
                    Text("布局、排序和卡片信息会即时更新")
                        .font(.caption)
                        .foregroundStyle(GraphiteTheme.panelSecondaryText)
                }
            }
            .padding(.bottom, 14)

            settingsSection("排列与排序", systemImage: "rectangle.grid.2x2") {
                LabeledContent("布局方式") {
                    Picker("布局方式", selection: $layoutMode) {
                        ForEach(AssetGalleryLayoutMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 168)
                }

                Divider()

                LabeledContent("主排序") {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(AssetSortField.allCases) { field in
                                Button {
                                    sort.setField(field, at: 0)
                                } label: {
                                    if field == primaryCriterion.field {
                                        Label(field.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(field.rawValue)
                                    }
                                }
                                .disabled(secondaryFields.contains(field))
                            }
                        } label: {
                            HStack {
                                Text(primaryCriterion.field.rawValue)
                                    .foregroundStyle(GraphiteTheme.panelText)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
                            }
                            .padding(.horizontal, 9)
                            .frame(width: 112, height: 28)
                            .background(GraphiteTheme.assetWell, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        directionButton(.descending, systemImage: "arrow.down")
                        directionButton(.ascending, systemImage: "arrow.up")
                    }
                }

                if sort.criteria.count > 1 {
                    Text("已保留 \(sort.criteria.count - 1) 项次级排序，可在顶部“排序规则”中调整优先级。")
                        .font(.caption)
                        .foregroundStyle(GraphiteTheme.panelSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }

                Divider()

                LabeledContent("缩略图大小") {
                    GalleryThumbnailSizeControl(width: $thumbnailWidth, compact: false)
                        .frame(width: 180)
                }
            }

            settingsSection("卡片信息", systemImage: "text.below.photo") {
                settingToggle("显示名称", isOn: $showsName)
                settingDivider
                settingToggle("显示简介", isOn: $showsDescription)
                settingDivider
                settingToggle("显示扩展名", isOn: $showsExtension, enabled: showsName)
                settingDivider
                settingToggle("显示尺寸与文件大小", isOn: $showsSecondaryInfo)

                LabeledContent("信息内容") {
                    Picker("信息内容", selection: $secondaryInfoMode) {
                        ForEach(AssetSecondaryInfoMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 168)
                }
                .disabled(!showsSecondaryInfo)
                .opacity(showsSecondaryInfo ? 1 : 0.45)
                .padding(.leading, 16)
                .padding(.vertical, 5)

                settingDivider
                settingToggle("显示标签", isOn: $showsTags)
                settingDivider
                settingToggle("显示标签数", isOn: $showsTagCount)
                settingDivider
                settingToggle("显示评分", isOn: $showsRating)
            }

            settingsSection("浏览区域", systemImage: "sidebar.left") {
                LabeledContent("子文件夹内容") {
                    Picker("子文件夹内容", selection: $folderScope) {
                        ForEach(LocalFolderScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 168)
                }
                .disabled(!folderScopeEnabled)
                .opacity(folderScopeEnabled ? 1 : 0.45)
                .padding(.vertical, 5)

                settingDivider
                settingToggle("显示侧栏", isOn: $showsSidebar)
                settingDivider
                settingToggle("显示检查器", isOn: $showsInspector)
            }

            Label("设置会自动保存", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(GraphiteTheme.panelSecondaryText)
                .padding(.top, 12)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(18)
        .frame(width: 420)
        .background(GraphiteTheme.inspector)
        .foregroundStyle(GraphiteTheme.panelText)
    }

    private var primaryCriterion: AssetSortCriterion {
        sort.criteria[0]
    }

    private var secondaryFields: Set<AssetSortField> {
        Set(sort.criteria.dropFirst().map(\.field))
    }

    private var settingDivider: some View {
        Divider().padding(.leading, 2)
    }

    private func directionButton(_ direction: AssetSortDirection, systemImage: String) -> some View {
        let selected = primaryCriterion.direction == direction
        return Button(direction == .descending ? "降序" : "升序", systemImage: systemImage) {
            sort.setDirection(direction, at: 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: 30, height: 28)
        .foregroundStyle(selected ? Color.white : GraphiteTheme.panelSecondaryText)
        .background(selected ? GraphiteTheme.accent : GraphiteTheme.assetWell, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.clear : GraphiteTheme.panelStroke, lineWidth: 1)
        }
        .accessibilityLabel(direction == .descending ? "按降序排列" : "按升序排列")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .padding(.vertical, 6)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .bold()
                .foregroundStyle(GraphiteTheme.panelText)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(GraphiteTheme.panelStroke, lineWidth: 1)
            }
        }
        .padding(.bottom, 14)
    }
}
