import SwiftUI

struct AssetSortEditor: View {
    @Binding var sort: AssetSortConfiguration
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("排序规则", systemImage: "arrow.up.arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(GraphiteTheme.panelText)
                    Text("数字越小优先级越高；前一项相同时，才比较下一项。")
                        .font(.callout)
                        .foregroundStyle(GraphiteTheme.panelSecondaryText)
                }
                Spacer(minLength: 12)
                Button("完成", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
            }

            AssetSortRuleSummary(criteria: sort.criteria)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GraphiteTheme.assetWell, in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 8) {
                ForEach(Array(sort.criteria.enumerated()), id: \.element.id) { index, criterion in
                    AssetSortCriterionRow(
                        criterion: criterion,
                        index: index,
                        totalCount: sort.criteria.count,
                        unavailableFields: unavailableFields(except: index),
                        selectField: { sort.setField($0, at: index) },
                        toggleDirection: { sort.toggleDirection(at: index) },
                        moveUp: { sort.move(from: index, offset: -1) },
                        moveDown: { sort.move(from: index, offset: 1) },
                        remove: { sort.remove(at: index) }
                    )
                }
            }

            Divider()

            HStack(spacing: 12) {
                Menu {
                    ForEach(sort.availableFields) { field in
                        Button(field.rawValue) { sort.add(field: field) }
                    }
                } label: {
                    Label("添加排序条件", systemImage: "plus.circle.fill")
                        .foregroundStyle(GraphiteTheme.panelText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(sort.criteria.count >= AssetSortConfiguration.maximumCriteria || sort.availableFields.isEmpty)

                Spacer()

                Button("恢复默认", systemImage: "arrow.counterclockwise") {
                    sort.restoreDefault()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(GraphiteTheme.accent)
            }

            Text("最多可设置 \(AssetSortConfiguration.maximumCriteria) 项排序条件。")
                .font(.caption)
                .foregroundStyle(GraphiteTheme.panelSecondaryText)
        }
        .padding(18)
        .frame(width: 540)
        .background(GraphiteTheme.inspector)
        .foregroundStyle(GraphiteTheme.panelText)
    }

    private func unavailableFields(except index: Int) -> Set<AssetSortField> {
        Set(sort.criteria.enumerated().compactMap { offset, criterion in
            offset == index ? nil : criterion.field
        })
    }
}
