import SwiftUI

struct AssetComparisonView: View {
    @ObservedObject var store: AssetStore
    let assetIDs: [String]
    let onClose: () -> Void

    @State private var zoom = 1.0

    private var assets: [AssetItem] {
        assetIDs.compactMap(store.asset(withID:))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                let count = max(1, assets.count)
                let width = max(190, (geometry.size.width - CGFloat(count - 1) * 10 - 24) / CGFloat(count))
                HStack(spacing: 10) {
                    ForEach(assets) { asset in
                        comparisonCard(asset, width: width)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 880, idealWidth: 1_180, minHeight: 620, idealHeight: 760)
        .background(GraphiteTheme.canvas)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("候选对比")
                    .font(.title2.bold())
                Text("\(assets.count) 张并排 · 同步缩放 · 评分与审核状态写回同一动作层")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("同步缩放", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...3, step: 0.1)
                .frame(width: 150)
            Text("\(zoom, format: .number.precision(.fractionLength(1)))×")
                .font(.caption.monospacedDigit())
                .frame(width: 34)
            Button("重置", action: { zoom = 1 })
                .disabled(zoom == 1)
            Button("关闭", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .background(.bar)
    }

    private func comparisonCard(_ asset: AssetItem, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black.opacity(0.92)
                AssetThumbnail(
                    asset: asset,
                    size: CGSize(width: max(150, width - 20), height: 430),
                    contentMode: .fit,
                    backgroundColor: .clear,
                    opensPreview: true,
                    showsOverlays: false
                )
                .scaleEffect(zoom)
            }
            .frame(height: 430)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in zoom = min(3, max(1, value.magnification)) }
            )

            Text(asset.name)
                .font(.headline)
                .lineLimit(2)
                .help(asset.name)
            HStack {
                AssetRatingControl(
                    rating: asset.starRating,
                    onChange: { _ = store.performSetRating($0, on: [.formal(asset.id)]) }
                )
                Spacer()
                Text(asset.dimensionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker("候选结论", selection: decisionBinding(asset.id)) {
                Text("保留").tag(UserDecision.confirmed)
                Text("备用").tag(UserDecision.pending)
                Text("废片").tag(UserDecision.rejected)
            }
            .pickerStyle(.segmented)
            Button("在 Finder 中显示", systemImage: "folder") {
                store.performReveal(.formal(asset.id))
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    private func decisionBinding(_ id: String) -> Binding<UserDecision> {
        Binding(
            get: { store.asset(withID: id)?.decision ?? .pending },
            set: { decision in _ = store.performSetDecision(decision, on: [.formal(id)]) }
        )
    }
}
