import SwiftUI

struct AssetScopeInspector: View {
    let summary: InspectorScopeSummary
    let assets: [AssetItem]
    let onClose: () -> Void

    private var fiveStarCount: Int { assets.lazy.filter { $0.starRating == 5 }.count }
    private var unclassifiedCount: Int { assets.lazy.filter { $0.type == .unclassified }.count }
    private var leadingFormats: [String] {
        let counts = assets.reduce(into: [String: Int]()) { result, asset in
            let value = AssetFileFormat.normalizedExtension(for: asset).uppercased()
            if !value.isEmpty { result[value, default: 0] += 1 }
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(4).map { "\($0.key) \($0.value)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorPaneHeader(title: "当前范围", subtitle: summary.queryIsActive ? "当前搜索与筛选结果" : "未选择素材时显示范围摘要", onClose: onClose)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: summary.queryIsActive ? "line.3.horizontal.decrease.circle" : "folder.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        Text(summary.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary.queryIsActive ? "统计仅包含当前可见结果" : "这是当前正在浏览的素材范围")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        InspectorMetricCard(value: "\(summary.itemCount)", label: "素材")
                        InspectorMetricCard(value: summary.totalFileSize.formatted(.byteCount(style: .file)), label: "总大小")
                    }

                    InspectorSection(title: "范围概览") {
                        VStack(alignment: .leading, spacing: 8) {
                            InspectorInfoRow(title: "5 星", value: "\(fiveStarCount)")
                            InspectorInfoRow(title: "待整理", value: "\(unclassifiedCount)")
                            InspectorInfoRow(title: "文件异常", value: "\(summary.missingSourceCount)")
                            InspectorInfoRow(title: "主要格式", value: leadingFormats.isEmpty ? "待识别" : leadingFormats.joined(separator: " · "))
                        }
                    }

                    Label("选中素材后，这里会立即切换为预览与可编辑信息；多选时切换为批量检查器。", systemImage: "cursorarrow.click.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(GraphiteTheme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.inspector)
    }
}

struct AssetBatchInspector: View {
    @ObservedObject var store: AssetStore
    let summary: InspectorBatchSummary
    let onClearSelection: () -> Void
    let onClose: () -> Void

    @State private var tagDraft = ""

    private var formalAssets: [AssetItem] {
        summary.formalIDs.sorted().compactMap(store.asset(withID:))
    }
    private var pendingItems: [PendingImportItem] {
        summary.pendingIDs.sorted().compactMap(store.pendingImport(withID:))
    }
    private var previewAssets: [AssetItem] {
        formalAssets + pendingItems.map(\.previewAsset)
    }
    private var uniformRating: Int? {
        guard let first = formalAssets.first?.starRating,
              formalAssets.dropFirst().allSatisfy({ $0.starRating == first }) else { return nil }
        return first
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorPaneHeader(title: "批量检查器", subtitle: "已选 \(summary.itemCount) 项", onClose: onClose)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    batchPreview

                    HStack(spacing: 10) {
                        InspectorMetricCard(value: "\(summary.itemCount)", label: "已选择")
                        InspectorMetricCard(value: summary.totalFileSize.formatted(.byteCount(style: .file)), label: "总大小")
                    }

                    if !summary.pendingIDs.isEmpty {
                        Label("包含 \(summary.pendingIDs.count) 项待确认素材；批量类型和标签会分别写入对应上下文。", systemImage: "tray.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if formalAssets.isEmpty {
                        Label("待确认素材入库前不写评分", systemImage: "star.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        InspectorSection(title: "评分") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    AssetRatingControl(rating: uniformRating ?? 0, onChange: applyRating)
                                    Spacer(minLength: 0)
                                }
                                if uniformRating == nil, formalAssets.count > 1 {
                                    Text("当前评分不一致；点击星级可统一正式资产评分。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !pendingItems.isEmpty {
                                    Text("待确认素材入库前不写评分。")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    InspectorSection(title: "批量分类") {
                        VStack(alignment: .leading, spacing: 8) {
                            Menu("设置资产类型", systemImage: "tag") {
                                ForEach(AssetType.allCases) { type in
                                    Button(type.rawValue) { applyType(type) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if !formalAssets.isEmpty {
                                Menu("设置审核状态", systemImage: "checkmark.circle") {
                                    ForEach(UserDecision.allCases) { decision in
                                        Button(decision.rawValue) {
                                            _ = store.performSetDecision(
                                                decision,
                                                on: Set(summary.formalIDs.map(AssetActionTarget.formal))
                                            )
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    InspectorSection(title: "标签") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                TextField("输入标签，按回车添加", text: $tagDraft)
                                    .onSubmit(addTags)
                                Button("添加", systemImage: "plus", action: addTags)
                                    .labelStyle(.iconOnly)
                                    .disabled(tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if !store.availableTags.isEmpty {
                                Menu("从已有标签选择", systemImage: "tag.fill") {
                                    ForEach(store.availableTags, id: \.self) { tag in
                                        Button(tag) { applyTags([tag]) }
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    InspectorSection(title: "基本信息") {
                        VStack(alignment: .leading, spacing: 8) {
                            InspectorInfoRow(title: "正式资产", value: "\(summary.formalIDs.count)")
                            InspectorInfoRow(title: "待确认", value: "\(summary.pendingIDs.count)")
                            InspectorInfoRow(title: "文件异常", value: "\(summary.missingSourceCount)")
                        }
                    }

                    Button("取消选择", systemImage: "xmark.circle", action: onClearSelection)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.inspector)
    }

    private var batchPreview: some View {
        ZStack {
            ForEach(Array(previewAssets.prefix(4).enumerated()), id: \.element.id) { index, asset in
                AssetPreviewThumbnail(
                    asset: asset,
                    size: CGSize(width: 280, height: 150),
                    contentMode: .fit,
                    isEnabled: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .offset(x: CGFloat(index) * 4, y: CGFloat(index) * -4)
            }
        }
        .frame(height: 158)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .overlay(alignment: .bottomLeading) {
            Label("已选 \(summary.itemCount) 项", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: Capsule())
                .padding(8)
        }
    }

    private func applyRating(_ rating: Int) {
        guard !summary.formalIDs.isEmpty else { return }
        _ = store.performSetRating(rating, on: Set(summary.formalIDs.map(AssetActionTarget.formal)))
    }

    private func applyType(_ type: AssetType) {
        store.performSetType(type, on: actionTargets)
    }

    private func addTags() {
        let tags = tagDraft
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tags.isEmpty else { return }
        applyTags(tags)
        tagDraft = ""
    }

    private func applyTags(_ tags: [String]) {
        store.performAddTags(tags, on: actionTargets)
    }

    private var actionTargets: Set<AssetActionTarget> {
        Set(summary.formalIDs.map(AssetActionTarget.formal))
            .union(summary.pendingIDs.map(AssetActionTarget.pending))
    }
}

struct InspectorPaneHeader: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("收起详情", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("收起详情")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }
}

struct GlobalFiveStarAssetInspector: View {
    @ObservedObject var store: GlobalFiveStarStore
    let record: GlobalFiveStarRecord
    let onClose: () -> Void

    private var asset: AssetItem { record.galleryAsset }

    var body: some View {
        VStack(spacing: 0) {
            InspectorPaneHeader(title: "五星检查器", subtitle: "跨项目来源 · 只读", onClose: onClose)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AssetInspectorPreview(asset: asset)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(asset.name).font(.headline).textSelection(.enabled)
                        Text(asset.originalFilename).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }

                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { value in
                            Image(systemName: value <= asset.starRating ? "star.fill" : "star")
                                .foregroundStyle(value <= asset.starRating ? GraphiteTheme.star : Color.secondary)
                        }
                        Text(asset.starRating == 0 ? "未评分" : "\(asset.starRating) 星")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 5)
                    }

                    if !asset.normalizedTags.isEmpty {
                        InspectorSection(title: "标签") {
                            Text(asset.normalizedTags.joined(separator: " · "))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    InspectorSection(title: "来源项目") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(record.sourceProjectNames, id: \.self) { name in
                                Label(name, systemImage: "folder")
                                    .font(.caption)
                            }
                        }
                    }

                    InspectorSection(title: "基本信息") {
                        let metadata = AssetInspectorMetadata(asset: asset, filePath: AssetStore.bestAvailableSource(for: asset)?.path)
                        VStack(alignment: .leading, spacing: 8) {
                            InspectorInfoRow(title: "尺寸", value: metadata.dimensionText)
                            InspectorInfoRow(title: "文件大小", value: metadata.fileSizeText)
                            InspectorInfoRow(title: "格式", value: metadata.formatText)
                            InspectorInfoRow(title: "文件状态", value: asset.sourceMissing ? "已失联" : "正常")
                            InspectorInfoRow(title: "加入日期", value: metadata.createdAtText)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Finder", systemImage: "folder") { store.reveal(record) }
                        Button("复制路径", systemImage: "doc.on.doc") { store.copyPath(record) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("五星库聚合多个项目来源；为避免跨项目误写，字段修改请回到所属项目资产。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.inspector)
    }
}

struct GlobalFiveStarBatchInspector: View {
    let records: [GlobalFiveStarRecord]
    let onClearSelection: () -> Void
    let onClose: () -> Void

    private var assets: [AssetItem] { records.map(\.galleryAsset) }
    private var totalFileSize: Int64 {
        assets.reduce(Int64(0)) { $0 + max(0, $1.sourceFileSize ?? 0) }
    }
    private var sourceProjects: [String] {
        Array(Set(records.flatMap(\.sourceProjectNames))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorPaneHeader(title: "五星批量检查器", subtitle: "已选 \(records.count) 项", onClose: onClose)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        ForEach(Array(assets.prefix(4).enumerated()), id: \.element.id) { index, asset in
                            AssetPreviewThumbnail(asset: asset, size: CGSize(width: 280, height: 150), contentMode: .fit, isEnabled: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .offset(x: CGFloat(index) * 4, y: CGFloat(index) * -4)
                        }
                    }
                    .frame(height: 158)
                    .padding(.trailing, 12)
                    .padding(.top, 12)

                    HStack(spacing: 10) {
                        InspectorMetricCard(value: "\(records.count)", label: "已选择")
                        InspectorMetricCard(value: totalFileSize.formatted(.byteCount(style: .file)), label: "总大小")
                    }

                    InspectorSection(title: "来源项目") {
                        Text(sourceProjects.joined(separator: " · "))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("引用和移出项目等批量动作继续使用画册顶部操作条；右栏只提供当前选择摘要。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("取消选择", systemImage: "xmark.circle", action: onClearSelection)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.inspector)
    }
}

struct InspectorMetricCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GraphiteTheme.card.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value).lineLimit(1).help(value).textSelection(.enabled)
        }
        .font(.caption)
    }
}
