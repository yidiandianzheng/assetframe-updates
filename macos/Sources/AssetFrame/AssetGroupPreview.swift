import AppKit
import Combine
import SwiftUI

@MainActor
final class AssetPreviewSessionModel: ObservableObject {
    enum Mode { case detail, grid }

    let session: AssetPreviewSession
    @Published private(set) var items: [AssetPreviewItem]
    @Published private(set) var selectedIndex: Int
    @Published private(set) var preferredAssetID: String?
    @Published var mode: Mode = .detail

    init(session: AssetPreviewSession) {
        self.session = session
        items = session.items
        selectedIndex = min(max(0, session.initialIndex), max(0, session.items.count - 1))
        preferredAssetID = session.preferredAssetID
    }

    var currentItem: AssetPreviewItem { items[selectedIndex] }
    var canSelectPrevious: Bool { selectedIndex > 0 }
    var canSelectNext: Bool { selectedIndex + 1 < items.count }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        mode = .detail
    }

    func selectPrevious() {
        guard canSelectPrevious else { return }
        selectedIndex -= 1
    }

    func selectNext() {
        guard canSelectNext else { return }
        selectedIndex += 1
    }

    func toggleMode() { mode = mode == .detail ? .grid : .detail }

    func isPreferred(_ assetID: String) -> Bool {
        preferredAssetID == assetID
    }

    func setPreferred(_ assetID: String) {
        guard items.contains(where: { $0.id == assetID }) else { return }
        items = AssetPreviewSession.promotingPreferred(assetID, in: items)
        preferredAssetID = assetID
        selectedIndex = 0
    }

    func prefetchAdjacentThumbnails() {
        let indexes = [selectedIndex - 1, selectedIndex + 1].filter(items.indices.contains)
        let assets = indexes.map { items[$0].asset }
        ThumbnailPipeline.shared.prefetch(
            assets: assets,
            size: CGSize(width: 220, height: 146)
        )
    }

    func cancelPrefetch() {}
}

struct AssetGroupPreview: View {
    @ObservedObject var model: AssetPreviewSessionModel
    let onSetPreferred: (String) -> Bool
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if model.mode == .detail {
                AssetImagePreview(asset: model.currentItem.asset, onClose: onClose)
                .id(previewIdentity)
                .transition(.opacity)
            } else {
                gridOverview
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if model.mode == .detail { filmstrip }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.mode)
        .onAppear { model.prefetchAdjacentThumbnails() }
        .onChange(of: model.selectedIndex) { _, _ in model.prefetchAdjacentThumbnails() }
        .onChange(of: model.preferredAssetID) { _, _ in model.prefetchAdjacentThumbnails() }
        .onDisappear { model.cancelPrefetch() }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("\(model.selectedIndex + 1) / \(model.items.count)")
                        .font(.headline.monospacedDigit())
                    Text(model.currentItem.asset.originalFilename.isEmpty
                         ? model.currentItem.asset.name
                         : model.currentItem.asset.originalFilename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 7) {
                    Text(model.currentItem.asset.dimensionText)
                    Text("·")
                    Label(model.currentItem.statusText, systemImage: statusSymbol(model.currentItem.decision))
                    if model.isPreferred(model.currentItem.id) {
                        Text("·")
                        Label("首选图", systemImage: "star.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(action: model.selectPrevious) {
                Label("上一张", systemImage: "chevron.left")
            }
            .disabled(!model.canSelectPrevious)
            .help("上一张（←）")
            Button(action: model.selectNext) {
                Label("下一张", systemImage: "chevron.right")
            }
            .disabled(!model.canSelectNext)
            .help("下一张（→）")
            Button(action: model.toggleMode) {
                Label(
                    model.mode == .detail ? "九宫格" : "大图",
                    systemImage: model.mode == .detail ? "square.grid.3x3" : "photo"
                )
            }
            .help(model.mode == .detail ? "查看全部照片" : "返回当前大图")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        let preferred = model.isPreferred(item.id)
                        Button { model.select(index) } label: {
                            filmstripItem(item, selected: index == model.selectedIndex, preferred: preferred)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .padding(.trailing, preferred && model.items.count > 1 ? 52 : 0)
                        .contextMenu {
                            if preferred {
                                Label("当前首选图", systemImage: "star.fill")
                            } else {
                                Button("重设为首选图", systemImage: "star") {
                                    setPreferred(item.id)
                                }
                            }
                        }
                        .accessibilityLabel("第 \(index + 1) 张，\(preferred ? "首选图，" : "")\(item.asset.name)，\(item.statusText)")
                        .accessibilityValue(index == model.selectedIndex ? "当前照片" : "")
                        .accessibilityAction(named: "重设为首选图") { setPreferred(item.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .onAppear { proxy.scrollTo(model.currentItem.id, anchor: .center) }
            .onChange(of: model.selectedIndex) { _, _ in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                    proxy.scrollTo(model.currentItem.id, anchor: .center)
                }
            }
            .onChange(of: model.preferredAssetID) { _, preferredAssetID in
                guard let preferredAssetID else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                    proxy.scrollTo(preferredAssetID, anchor: .leading)
                }
            }
        }
        .frame(height: 104)
    }

    private func filmstripItem(_ item: AssetPreviewItem, selected: Bool, preferred: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AssetThumbnail(asset: item.asset, size: CGSize(width: 104, height: 72), contentMode: .fit)
            Image(systemName: statusSymbol(item.decision))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor(item.decision))
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .padding(5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: selected ? 3 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                .padding(5)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if preferred {
                Label("首选图", systemImage: "star.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(5)
            }
        }
        .padding(3)
    }

    private var gridOverview: some View {
        ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 16) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    let preferred = model.isPreferred(item.id)
                    Button { model.select(index) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            ZStack(alignment: .topLeading) {
                                AssetThumbnail(asset: item.asset, size: CGSize(width: 220, height: 146), contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                Text("\(index + 1)")
                                    .font(.caption.bold().monospacedDigit())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(7)
                                if preferred {
                                    Label("首选图", systemImage: "star.fill")
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(.regularMaterial, in: Capsule())
                                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                                        .padding(7)
                                }
                            }
                            Text(item.asset.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            HStack {
                                Label(item.statusText, systemImage: statusSymbol(item.decision))
                                    .foregroundStyle(statusColor(item.decision))
                                Spacer()
                                Text(item.asset.resolutionLabel)
                            }
                            .font(.caption)
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(index == model.selectedIndex ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: index == model.selectedIndex ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if preferred {
                            Label("当前首选图", systemImage: "star.fill")
                        } else {
                            Button("重设为首选图", systemImage: "star") {
                                setPreferred(item.id)
                            }
                        }
                    }
                    .accessibilityLabel("第 \(index + 1) 张，\(preferred ? "首选图，" : "")\(item.asset.name)，\(item.statusText)")
                    .accessibilityHint("打开这张照片的大图预览")
                    .accessibilityAction(named: "重设为首选图") { setPreferred(item.id) }
                }
            }
            .padding(.top, 72)
            .padding(20)
        }
    }

    private var previewIdentity: String {
        let asset = model.currentItem.asset
        let source = AssetStore.bestAvailableSource(for: asset)
        return "\(asset.id)|\(source?.path ?? "missing")|\(source?.modifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func setPreferred(_ assetID: String) {
        guard !model.isPreferred(assetID), onSetPreferred(assetID) else { return }
        model.setPreferred(assetID)
    }

    private func statusSymbol(_ decision: VariantCandidateDecision?) -> String {
        switch decision {
        case .main: "checkmark.seal.fill"
        case .reference: "photo.stack.fill"
        case .unused: "xmark.bin.fill"
        case .pending: "questionmark.circle"
        case nil: "photo"
        }
    }

    private func statusColor(_ decision: VariantCandidateDecision?) -> Color {
        switch decision {
        case .main: .green
        case .reference: .blue
        case .unused: .red
        case .pending: .secondary
        case nil: .secondary
        }
    }
}
