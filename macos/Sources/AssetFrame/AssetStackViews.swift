import SwiftUI

struct AssetStackCreationDraft: Identifiable {
    let id = UUID()
    var assetIDs: [String]
    var defaultName: String
    var defaultCoverID: String
}

struct AssetStackSheetRoute: Identifiable { var id: String }

struct AssetStackCreationView: View {
    @ObservedObject var store: AssetStore
    let draft: AssetStackCreationDraft
    let onClose: () -> Void
    @State private var selectedEntityID: String?
    @State private var entityName: String
    @State private var variantName = "基础"
    @State private var type: AssetType
    @State private var coverAssetID: String

    init(store: AssetStore, draft: AssetStackCreationDraft, onClose: @escaping () -> Void) {
        self.store = store
        self.draft = draft
        self.onClose = onClose
        let firstType = draft.assetIDs.compactMap(store.asset(withID:)).first?.type ?? .unclassified
        _entityName = State(initialValue: draft.defaultName)
        _type = State(initialValue: firstType)
        _coverAssetID = State(initialValue: draft.defaultCoverID)
    }

    private var assets: [AssetItem] { draft.assetIDs.compactMap(store.asset(withID:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("建立待裁定形态").font(.title2.bold())
                Text("同一稳定形态的候选图放在一起。现在只建立裁定组，不会自动选择正式主图。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Picker("资产主体", selection: $selectedEntityID) {
                    Text("新建资产主体").tag(String?.none)
                    ForEach(store.assetEntities) { entity in
                        Text("\(entity.code) · \(entity.name)").tag(Optional(entity.id))
                    }
                }
                .onChange(of: selectedEntityID) { _, value in
                    guard let value, let entity = store.entity(withID: value) else { return }
                    entityName = entity.name
                    type = entity.type
                }
                TextField("主体名称，例如：桑枝", text: $entityName).disabled(selectedEntityID != nil)
                Picker("资产类型", selection: $type) {
                    ForEach([AssetType.person, .scene, .prop], id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(selectedEntityID != nil)
                TextField("形态名称，例如：基础、战损、夜景", text: $variantName)
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 9) {
                Text("建议封面（不是正式主图）").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(assets) { asset in
                            Button { coverAssetID = asset.id } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    AssetThumbnail(asset: asset, size: CGSize(width: 150, height: 102), contentMode: .fit)
                                        .frame(width: 150, height: 102)
                                    Label(asset.name, systemImage: coverAssetID == asset.id ? "checkmark.circle.fill" : "circle")
                                        .font(.caption).lineLimit(1)
                                }
                                .padding(8)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).stroke(coverAssetID == asset.id ? Color.accentColor : .clear, lineWidth: 2) }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Label("\(assets.count) 张候选", systemImage: "square.stack.3d.up.fill").foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("建立形态") {
                    store.createAssetVariant(
                        assetIDs: Set(draft.assetIDs), entityID: selectedEntityID,
                        entityName: entityName, type: type, variantName: variantName,
                        suggestedCoverID: coverAssetID
                    )
                    onClose()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(assets.count < 2 || entityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || variantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 780)
    }
}

struct AssetStackDetailView: View {
    @ObservedObject var store: AssetStore
    let stackID: String
    @Environment(\.dismiss) private var dismiss
    @State private var entityName = ""
    @State private var variantName = ""
    @State private var keyDifference = ""
    @State private var doNotMix = ""

    private var variant: AssetVariantRecord? { store.stack(withID: stackID) }
    private var assets: [AssetItem] { variant?.memberAssetIDs.compactMap(store.asset(withID:)) ?? [] }
    private var issues: [String] { store.variantLockIssues(stackID) }
    private let columns = [GridItem(.adaptive(minimum: 205, maximum: 250), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if variant == nil {
                ContentUnavailableView("形态组已经解散", systemImage: "square.stack.3d.up.slash")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metadataCard
                        if !issues.isEmpty, variant?.isLocked != true {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("锁定前还需完成", systemImage: "exclamationmark.triangle.fill").bold()
                                ForEach(issues, id: \.self) { Text("• \($0)") }
                            }
                            .font(.caption).foregroundStyle(.orange)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(assets) { asset in CandidateDecisionCard(
                                asset: asset,
                                decision: variant?.decisions[asset.id, default: .pending] ?? .pending,
                                onDecision: { store.setVariantDecision(stackID, assetID: asset.id, decision: $0) },
                                onRemove: { store.removeAssetFromStack(asset.id) }
                            ) }
                        }
                    }.padding(18)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 700)
        .onAppear(perform: loadFields)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(variant?.isLocked == true ? "正式形态" : "候选裁定台").font(.caption).foregroundStyle(.secondary)
                Text(variant?.effectiveCallCode ?? "形态已删除").font(.title3.monospaced()).bold()
                if let variant { Text("\(variant.count) 张候选 · \(variant.versionText)" + (variant.requiresExport ? " · 需要重新导出" : " · 已交付")).font(.caption).foregroundStyle(variant.requiresExport ? .orange : .secondary) }
            }
            Spacer()
            if let variant {
                if variant.isLocked {
                    Button("加入导出库", systemImage: "shippingbox.badge.plus") { store.addVariantToExportLibrary(stackID) }
                    Button("解锁继续裁定") { store.unlockVariant(stackID) }
                } else {
                    Button("一键锁定并淘汰其余", systemImage: "lock.fill") {
                        saveFields()
                        store.lockVariant(stackID)
                    }
                    .buttonStyle(.borderedProminent).disabled(!issues.isEmpty)
                }
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("解散形态组", role: .destructive) { store.unstack(stackID); dismiss() }
                }
                .labelStyle(.iconOnly)
            }
            Button("完成") { saveFields(); dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(18)
    }

    private var metadataCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text("资产主体")
                TextField("例如：桑枝", text: $entityName)
                Text("形态名称")
                TextField("例如：战损", text: $variantName)
            }
            GridRow {
                Text("形态关键区别")
                TextField("一句话写清与其他形态最明显的区别", text: $keyDifference).gridCellColumns(3)
            }
            GridRow {
                Text("禁止混用")
                TextField("例如：不得混用基础白衣版、不得替换发饰", text: $doNotMix).gridCellColumns(3)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: entityName) { _, _ in saveFields() }
        .onChange(of: variantName) { _, _ in saveFields() }
        .onChange(of: keyDifference) { _, _ in saveFields() }
        .onChange(of: doNotMix) { _, _ in saveFields() }
    }

    private func loadFields() {
        guard let variant else { return }
        entityName = store.entity(for: variant)?.name ?? ""
        variantName = variant.effectiveVariantName
        keyDifference = variant.keyDifference ?? ""
        doNotMix = variant.doNotMix ?? ""
    }

    private func saveFields() {
        guard variant != nil else { return }
        store.updateVariantMetadata(stackID, entityName: entityName, variantName: variantName, keyDifference: keyDifference, doNotMix: doNotMix)
    }
}

private struct CandidateDecisionCard: View {
    let asset: AssetItem
    let decision: VariantCandidateDecision
    let onDecision: (VariantCandidateDecision) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                AssetPreviewThumbnail(asset: asset, size: CGSize(width: 230, height: 150), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Text(decision.rawValue)
                    .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(decisionColor, in: Capsule()).foregroundStyle(.white).padding(8)
            }
            Text(asset.name).font(.system(size: 12).bold()).lineLimit(2)
            HStack(spacing: 6) {
                ForEach(VariantCandidateDecision.allCases) { value in
                    Button(value.rawValue) { onDecision(value) }
                        .buttonStyle(.borderedProminent)
                        .tint(decision == value ? color(for: value) : .gray.opacity(0.28))
                }
            }.controlSize(.small)
            HStack {
                Text(asset.resolutionLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("移出形态组", systemImage: "rectangle.portrait.and.arrow.right", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("移出形态组，不删除素材")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(decision == .main ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: decision == .main ? 2 : 1) }
    }

    private var decisionColor: Color { color(for: decision) }
    private func color(for value: VariantCandidateDecision) -> Color {
        switch value { case .pending: .gray; case .main: .blue; case .reference: .green; case .unused: .red }
    }
}
