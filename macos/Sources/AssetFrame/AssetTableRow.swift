import SwiftUI

struct AssetTableRow: View {
    @ObservedObject var store: AssetStore
    let asset: AssetItem
    let fields: [AssetTableField]
    let imageScale: AssetTableImageScale
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    private var tableWidth: CGFloat {
        fields.reduce(0) { $0 + $1.width(imageScale: imageScale) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(fields) { field in
                fieldCell(field)
                    .frame(
                        width: field.width(imageScale: imageScale),
                        height: imageScale.rowHeight,
                        alignment: .leading
                    )
                    .overlay(alignment: .trailing) { Divider() }
            }
        }
        .frame(width: tableWidth, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("记录优化建议备注…", systemImage: "square.and.pencil") {
                NotificationCenter.default.post(name: .recordOptimizationFeedback, object: nil)
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("移入回收站", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("资产记录，\(asset.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "选择资产记录", onSelect)
    }

    @ViewBuilder
    private func fieldCell(_ field: AssetTableField) -> some View {
        switch field {
        case .image:
            AssetThumbnail(asset: asset, size: imageScale.thumbnailSize, contentMode: .fit, opensPreview: true)
                .frame(maxWidth: .infinity)
        case .resolution:
            textCell("\(asset.resolutionLabel)\n\(asset.dimensionText)", bold: true)
        case .sourceStatus:
            Label(asset.sourceMissing ? "缺失" : "正常", systemImage: asset.sourceMissing ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(asset.sourceMissing ? Color.orange : Color.green)
                .padding(.horizontal, 8)
        case .name:
            TextField("资产名称", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(.callout)
                .bold()
                .lineLimit(1)
                .padding(.horizontal, 8)
        case .decision:
            enumPicker("审核状态", keyPath: \.decision, fallback: asset.decision, values: UserDecision.allCases)
        case .type:
            enumPicker("资产类型", keyPath: \.type, fallback: asset.type, values: AssetType.allCases)
        case .reuse:
            enumPicker("复用等级", keyPath: \.reuse, fallback: asset.reuse, values: ReuseGrade.allCases)
        case .rating:
            AssetRatingControl(rating: asset.starRating, compact: true, onChange: setRating)
                .padding(.horizontal, 6)
        case .tags:
            TextField("添加标签", text: tagsBinding)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 8)
        case .master:
            Toggle("通用资产", isOn: masterBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity)
        case .episodes:
            TextField("如：第1集", text: episodesBinding)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 8)
        case .candidatePlan:
            enumPicker("候选方案", keyPath: \.candidatePlan, fallback: asset.candidatePlan, values: CandidatePlan.allCases)
        case .qaResult:
            enumPicker("QA 结果", keyPath: \.qaResult, fallback: asset.qaResult, values: QAResult.allCases)
        case .operation:
            Button(role: .destructive, action: onDelete) {
                Label("移入回收站", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
        }
    }

    private func textCell(_ text: String, bold: Bool = false) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.caption)
            .bold(bold)
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .lineLimit(2)
            .padding(.horizontal, 8)
    }

    private func enumPicker<Value: Hashable & RawRepresentable & Identifiable>(
        _ title: String,
        keyPath: WritableKeyPath<AssetItem, Value>,
        fallback: Value,
        values: [Value]
    ) -> some View where Value.RawValue == String {
        Picker(title, selection: binding(keyPath, fallback: fallback)) {
            ForEach(values) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AssetItem, Value>, fallback: Value? = nil) -> Binding<Value> {
        Binding(
            get: { store.asset(withID: asset.id)?[keyPath: keyPath] ?? fallback ?? asset[keyPath: keyPath] },
            set: { value in store.performUpdate(keyPath, on: .formal(asset.id), to: value) }
        )
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { (store.asset(withID: asset.id)?.normalizedTags ?? asset.normalizedTags).joined(separator: "、") },
            set: { text in
                let tags = text
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                store.performUpdate(\.tags, on: .formal(asset.id), to: tags)
            }
        )
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { store.asset(withID: asset.id)?.isMaster ?? asset.isMaster },
            set: { value in _ = store.performSetCommon(value, on: [.formal(asset.id)]) }
        )
    }

    private var episodesBinding: Binding<String> {
        Binding(
            get: { (store.asset(withID: asset.id)?.episodes ?? asset.episodes).joined(separator: "、") },
            set: { text in
                let episodes = text
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                store.performUpdate(\.episodes, on: .formal(asset.id), to: episodes)
            }
        )
    }

    private func setRating(_ value: Int) {
        _ = store.performSetRating(value, on: [.formal(asset.id)])
    }
}
