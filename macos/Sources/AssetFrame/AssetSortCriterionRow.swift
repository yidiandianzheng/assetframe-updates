import SwiftUI

struct AssetSortCriterionRow: View {
    let criterion: AssetSortCriterion
    let index: Int
    let totalCount: Int
    let unavailableFields: Set<AssetSortField>
    let selectField: (AssetSortField) -> Void
    let toggleDirection: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(index == 0 ? GraphiteTheme.accent : GraphiteTheme.panelMutedText, in: Circle())
                .accessibilityLabel("第 \(index + 1) 优先级")

            fieldMenu
            directionButton

            Spacer(minLength: 0)

            actionButton("上移", systemImage: "chevron.up", disabled: index == 0, action: moveUp)
            actionButton("下移", systemImage: "chevron.down", disabled: index == totalCount - 1, action: moveDown)
            actionButton("删除", systemImage: "minus.circle", disabled: totalCount == 1, action: remove)
        }
        .padding(10)
        .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(GraphiteTheme.panelStroke, lineWidth: 1)
        }
    }

    private var fieldMenu: some View {
        Menu {
            ForEach(AssetSortField.allCases) { field in
                Button {
                    selectField(field)
                } label: {
                    if field == criterion.field {
                        Label(field.rawValue, systemImage: "checkmark")
                    } else {
                        Text(field.rawValue)
                    }
                }
                .disabled(unavailableFields.contains(field))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: criterion.field))
                    .foregroundStyle(GraphiteTheme.accent)
                    .frame(width: 18)
                Text(criterion.field.rawValue)
                    .font(.callout)
                    .foregroundStyle(GraphiteTheme.panelText)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
            }
            .padding(.horizontal, 10)
            .frame(width: 180, height: 44)
            .background(GraphiteTheme.assetWell, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(GraphiteTheme.panelStroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("排序类型，当前为\(criterion.field.rawValue)")
    }

    private var directionButton: some View {
        Button(action: toggleDirection) {
            HStack(spacing: 8) {
                Image(systemName: criterion.direction == .ascending ? "arrow.up" : "arrow.down")
                    .foregroundStyle(GraphiteTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("排序方式")
                        .font(.caption)
                        .foregroundStyle(GraphiteTheme.panelSecondaryText)
                    Text(criterion.directionLabel)
                        .font(.callout)
                        .foregroundStyle(GraphiteTheme.panelText)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(width: 142, height: 44)
            .background(GraphiteTheme.assetWell, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(GraphiteTheme.panelStroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击切换排序方向")
        .accessibilityLabel("排序方式，当前为\(criterion.directionLabel)")
    }

    private func actionButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 26, height: 32)
            .foregroundStyle(disabled ? GraphiteTheme.panelMutedText : GraphiteTheme.accent)
            .disabled(disabled)
    }

    private func icon(for field: AssetSortField) -> String {
        switch field {
        case .resolution: "arrow.up.left.and.arrow.down.right"
        case .fileSize: "doc.badge.gearshape"
        case .rating: "star"
        case .createdAt: "calendar.badge.plus"
        case .lastUsedAt: "clock.arrow.circlepath"
        case .sourceCreatedAt: "calendar"
        case .sourceModifiedAt: "calendar.badge.clock"
        case .name: "textformat"
        }
    }
}
