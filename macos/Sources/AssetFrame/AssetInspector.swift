import SwiftUI

struct AssetInspector: View {
    @ObservedObject var store: AssetStore
    let asset: AssetItem
    let onRequestRemoval: (String) -> Void
    let onClose: () -> Void

    @State private var moreInformationExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AssetInspectorPreview(asset: currentAsset)
                    identitySection
                    divider
                    tagsSection
                    divider
                    fileLocationSection
                    divider
                    basicInformationSection
                    divider
                    operationHistorySection
                    moreInformationSection
                    quickActions
                    destructiveAction
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.inspector)
    }

    private var currentAsset: AssetItem {
        store.asset(withID: asset.id) ?? asset
    }

    private var header: some View {
        InspectorPaneHeader(title: "素材检查器", subtitle: "单选 · 可直接编辑", onClose: onClose)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("照片名称", text: binding(\.name))
                .font(.body.weight(.medium))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Text("评分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AssetRatingControl(rating: currentAsset.starRating, onChange: updateRating)
                Spacer(minLength: 0)
            }

            TextField("添加备注", text: binding(\.note), axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            TextField("来源网址（可选）", text: sourceURLBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var tagsSection: some View {
        inspectorSection("标签") {
            AssetTagEditor(
                tags: currentAsset.normalizedTags,
                suggestions: store.availableTags,
                onChange: updateTags
            )
        }
    }

    private var fileLocationSection: some View {
        inspectorSection("所在位置") {
            AssetFileLocationsSection(store: store, assetID: asset.id, style: .plain)
        }
    }

    private var basicInformationSection: some View {
        let metadata = AssetInspectorMetadata(asset: currentAsset, filePath: store.fileLocation(for: asset.id)?.path)
        return inspectorSection("基本信息") {
            VStack(alignment: .leading, spacing: 7) {
                info("尺寸", metadata.dimensionText)
                info("文件大小", metadata.fileSizeText)
                info("格式", metadata.formatText)
                info("清晰度", currentAsset.resolutionLabel)
                info("文件状态", currentAsset.sourceMissing ? "已失联" : "正常")
                info("添加日期", metadata.createdAtText)
                info("创建日期", metadata.sourceCreatedAtText)
                info("修改日期", metadata.modifiedAtText)
            }
        }
    }

    private var moreInformationSection: some View {
        DisclosureGroup(isExpanded: $moreInformationExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                inspectorField("用户决策") { select(\.decision, UserDecision.allCases) }
                inspectorField("候选方案") { select(\.candidatePlan, CandidatePlan.allCases) }
                inspectorField("类型") { select(\.type, AssetType.allCases) }
                inspectorField("复用等级") { select(\.reuse, ReuseGrade.allCases) }
                MasterAssetControl(isMaster: currentAsset.isMaster, onChange: updateMasterStatus)
                inspectorField("资产图用途") { select(\.purpose, AssetPurpose.allCases) }
                inspectorField("资产归类") { select(\.category, AssetCategory.allCases) }
                inspectorField("QA 结果") { select(\.qaResult, QAResult.allCases) }
                inspectorField("生产状态") { select(\.productionStatus, ProductionStatus.allCases) }
                inspectorField("版本") { TextField("v01", text: binding(\.version)) }
                inspectorField("所属集数") { TextField("第1集,第2集", text: episodeBinding) }
                inspectorField("资产说明") {
                    TextField("填写资产说明", text: binding(\.assetDescription), axis: .vertical)
                        .lineLimit(2...5)
                }
                inspectorField("返修原因") {
                    TextField("如需返修，填写具体原因", text: binding(\.repairReason), axis: .vertical)
                        .lineLimit(2...4)
                }
                info("原始文件名", currentAsset.originalFilename)
                info("已保留原图版本", "\(currentAsset.sourceVersions?.count ?? 0)")
                info("资产 ID", currentAsset.id)
            }
            .padding(.top, 12)
        } label: {
            Label("更多资产信息", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
        }
        .padding(10)
        .background(GraphiteTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
    }

    private var operationHistorySection: some View {
        inspectorSection("操作历史摘要") {
            VStack(alignment: .leading, spacing: 7) {
                historyRow("建立索引", currentAsset.createdAt.formatted(date: .abbreviated, time: .shortened), icon: "tray.and.arrow.down")
                historyRow("评分", currentAsset.starRating == 0 ? "未评分" : "\(currentAsset.starRating) 星", icon: "star")
                historyRow("分类与审核", "\(currentAsset.type.rawValue) · \(currentAsset.decision.displayName)", icon: "tag")
                historyRow(
                    "原图替换",
                    currentAsset.sourceReplacedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未替换",
                    icon: "arrow.triangle.2.circlepath"
                )
                historyRow(
                    "最近使用",
                    currentAsset.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚无记录",
                    icon: "clock"
                )
                historyRow(
                    "受管副本",
                    managedCopySummary,
                    icon: "externaldrive.badge.checkmark"
                )
            }
        }
    }

    private var managedCopySummary: String {
        let paths = currentAsset.allSourceVersions
            .map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        let fiveStar = paths.contains { $0.contains("/05_五星精选/") } ? "五星精选" : nil
        let common = paths.contains { $0.contains("/06_通用资产/") } ? "通用资产" : nil
        let values = [fiveStar, common].compactMap { $0 }
        return values.isEmpty ? "未创建" : values.joined(separator: " · ")
    }

    private func historyRow(_ title: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            Button("预览", systemImage: "arrow.up.left.and.arrow.down.right", action: openPreview)
            Button("Finder", systemImage: "folder", action: revealInFinder)
            Button("替换高清版", systemImage: "arrow.up.doc", action: replaceWithHigherResolution)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var destructiveAction: some View {
        Button("移入回收站", systemImage: "trash", role: .destructive, action: moveToTrash)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var divider: some View {
        Divider().opacity(0.75)
    }

    private func openPreview() {
        NotificationCenter.default.post(name: .previewAssetImage, object: nil, userInfo: ["id": asset.id])
    }

    private func revealInFinder() { store.performReveal(.formal(asset.id)) }
    private func replaceWithHigherResolution() { store.chooseHigherResolutionReplacement(for: asset.id) }
    private func updateRating(_ value: Int) { _ = store.performSetRating(value, on: [.formal(asset.id)]) }
    private func updateTags(_ tags: [String]) { store.performUpdate(\.tags, on: .formal(asset.id), to: tags) }
    private func updateMasterStatus(_ value: Bool) { _ = store.performSetCommon(value, on: [.formal(asset.id)]) }

    private func moveToTrash() {
        onRequestRemoval(asset.id)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AssetItem, Value>) -> Binding<Value> {
        Binding(
            get: { store.asset(withID: asset.id)?[keyPath: keyPath] ?? asset[keyPath: keyPath] },
            set: { value in store.performUpdate(keyPath, on: .formal(asset.id), to: value) }
        )
    }

    private var episodeBinding: Binding<String> {
        Binding(
            get: { (store.asset(withID: asset.id)?.episodes ?? asset.episodes).joined(separator: ",") },
            set: { text in
                let episodes = text
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                store.performUpdate(\.episodes, on: .formal(asset.id), to: episodes)
            }
        )
    }

    private var sourceURLBinding: Binding<String> {
        Binding(
            get: { store.asset(withID: asset.id)?.sourceURL ?? asset.sourceURL ?? "" },
            set: { text in store.performUpdate(\.sourceURL, on: .formal(asset.id), to: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    private func select<Value: Hashable & RawRepresentable & Identifiable>(
        _ keyPath: WritableKeyPath<AssetItem, Value>,
        _ values: [Value]
    ) -> some View where Value.RawValue == String {
        Picker("", selection: binding(keyPath)) {
            ForEach(values) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func info(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .help(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
