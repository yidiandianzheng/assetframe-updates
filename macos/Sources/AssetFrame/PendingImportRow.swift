import SwiftUI

struct PendingImportRow: View {
    let item: PendingImportItem
    let showsSelectionControl: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onPreview: () -> Void
    let onTypeChange: (AssetType) -> Void
    let onCategoryChange: (AssetCategory) -> Void

    @State private var selectedType: AssetType
    @State private var selectedCategory: AssetCategory

    init(
        item: PendingImportItem,
        showsSelectionControl: Bool,
        isSelected: Bool,
        onToggleSelection: @escaping () -> Void,
        onPreview: @escaping () -> Void,
        onTypeChange: @escaping (AssetType) -> Void,
        onCategoryChange: @escaping (AssetCategory) -> Void
    ) {
        self.item = item
        self.showsSelectionControl = showsSelectionControl
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
        self.onPreview = onPreview
        self.onTypeChange = onTypeChange
        self.onCategoryChange = onCategoryChange
        _selectedType = State(initialValue: item.suggestedType)
        _selectedCategory = State(initialValue: item.category)
    }

    var body: some View {
        HStack(spacing: 14) {
            if showsSelectionControl {
                Button(
                    isSelected ? "取消选择“\(item.name)”" : "选择“\(item.name)”",
                    systemImage: isSelected ? "checkmark.circle.fill" : "circle",
                    action: onToggleSelection
                )
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .buttonStyle(.plain)
                    .contentTransition(.symbolEffect(.replace))
            }

            Button("查看“\(item.name)”高清原图", action: onPreview)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("查看高清原图")
                .overlay {
                    AssetThumbnail(
                        asset: item.previewAsset,
                        size: CGSize(width: 92, height: 66),
                        contentMode: .fit
                    )
                    .allowsHitTesting(false)
                }
                .frame(width: 92, height: 66)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(item.resolutionLabel, systemImage: "sparkles.rectangle.stack")
                    Text(item.dimensionText)
                    Text(item.originalFilename)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(item.originalSourcePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let provenance = item.generationProvenance {
                    Label(
                        "\(provenance.taskTitle) · \(provenance.candidateLabel)",
                        systemImage: "sparkles"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 8) {
                    Text("类型")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("资产类型", selection: $selectedType) {
                        ForEach(AssetType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                HStack(spacing: 8) {
                    Text("归类")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("资产归类", selection: $selectedCategory) {
                        ForEach(AssetCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
            }
        }
        .padding(.vertical, 5)
        .onChange(of: selectedType) { _, value in
            guard value != item.suggestedType else { return }
            onTypeChange(value)
        }
        .onChange(of: selectedCategory) { _, value in
            guard value != item.category else { return }
            onCategoryChange(value)
        }
        .onChange(of: item.suggestedType) { _, value in
            selectedType = value
        }
        .onChange(of: item.category) { _, value in
            selectedCategory = value
        }
    }
}
