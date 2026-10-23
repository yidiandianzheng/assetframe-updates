import SwiftUI

struct PendingReviewTypeFilterBar: View {
    let availableTypes: [AssetType]
    let selectedTypes: Set<AssetType>
    let currentType: AssetType?
    let filteredCount: Int
    let totalCount: Int
    let countForType: (AssetType) -> Int
    let onToggleType: (AssetType) -> Void
    let onSelectOnly: (AssetType) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("同类型图片筛选", systemImage: "square.grid.2x2")
                .font(.callout.bold())

            Menu {
                Button("显示全部类型", systemImage: "rectangle.stack", action: onClear)
                    .disabled(selectedTypes.isEmpty)

                if let currentType {
                    Button(
                        "只看当前类型：\(currentType.rawValue)",
                        systemImage: "scope"
                    ) {
                        onSelectOnly(currentType)
                    }
                }

                Divider()

                ForEach(availableTypes) { type in
                    Button {
                        onToggleType(type)
                    } label: {
                        Label(
                            "\(type.rawValue)（\(countForType(type)) 张）",
                            systemImage: selectedTypes.contains(type) ? "checkmark.square.fill" : "square"
                        )
                    }
                }
            } label: {
                Label(selectionLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("可同时勾选多个资产类型；同字段按“或”筛选")

            Text("显示 \(filteredCount) / \(totalCount) 张")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !selectedTypes.isEmpty {
                Button("清除筛选", systemImage: "xmark.circle", action: onClear)
                    .buttonStyle(.borderless)
            }

            Spacer()

            Text("可多选类型，再逐张保留或标为废片")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var selectionLabel: String {
        if selectedTypes.isEmpty {
            return "全部类型"
        }
        if selectedTypes.count == 1, let type = selectedTypes.first {
            return type.rawValue
        }
        return "已选 \(selectedTypes.count) 类"
    }
}
