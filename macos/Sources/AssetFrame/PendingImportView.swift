import SwiftUI

struct PendingImportView: View {
    @ObservedObject var store: AssetStore
    @State private var selectedIDs: Set<String> = []
    @State private var search = ""
    @State private var typeFilter: AssetType?
    @State private var sourceFilter = PendingImportSourceFilter.all
    @State private var resolutionFilter = "全部清晰度"
    @State private var isShowingVisualReview = false

    private let resolutionOptions = ["全部清晰度", "4K", "2K", "1K", "<1K", "待识别"]

    private var filteredItems: [PendingImportItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.pendingImports.filter { item in
            (query.isEmpty || "\(item.name) \(item.originalFilename) \(item.originalSourcePath)".localizedStandardContains(query)) &&
            (typeFilter == nil || item.suggestedType == typeFilter) &&
            sourceFilter.includes(item) &&
            (resolutionFilter == "全部清晰度" || item.resolutionLabel == resolutionFilter)
        }
    }

    private var groupedTypes: [AssetType] {
        AssetType.allCases.filter { type in filteredItems.contains(where: { $0.suggestedType == type }) }
    }

    private func items(for type: AssetType) -> [PendingImportItem] {
        filteredItems
            .filter { $0.suggestedType == type }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if store.pendingImports.isEmpty {
                ContentUnavailableView(
                    "待导入区为空",
                    systemImage: "tray",
                    description: Text("扫描、拖入或手动选择的图片会在这里建立原位索引")
                )
            } else if filteredItems.isEmpty {
                ContentUnavailableView("没有符合筛选条件的图片", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                List(selection: $selectedIDs) {
                    ForEach(groupedTypes) { type in
                        Section {
                            ForEach(items(for: type)) { item in
                                pendingRow(item)
                                    .tag(item.id)
                                    .contextMenu {
                                        Button("记录优化建议备注…", systemImage: "square.and.pencil") {
                                            NotificationCenter.default.post(name: .recordOptimizationFeedback, object: nil)
                                        }
                                        Divider()
                                        Button { preview(item) } label: { Label("查看高清原图", systemImage: "arrow.up.left.and.arrow.down.right") }
                                        Button { store.confirmPendingImports([item.id]) } label: { Label("确认导入", systemImage: "tray.and.arrow.down.fill") }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(type.rawValue).font(.headline)
                                Spacer()
                                Text("\(items(for: type).count) 项").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.pendingImports.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
        .sheet(isPresented: $isShowingVisualReview) {
            PendingReviewView(store: store, scopedIDs: nil) {
                isShowingVisualReview = false
            }
            .frame(minWidth: 980, minHeight: 700)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("待导入").font(.title2.weight(.semibold))
                Text("原位管理 · 只建立索引，不复制或移动原文件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = store.pendingVisionClassificationProgress {
                if progress.phase == .classifying {
                    ProgressView(value: progress.fraction)
                        .frame(width: 86)
                    Text("本机分类 \(progress.processed)/\(progress.total)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(progress.message, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(store.pendingImports.count) 项")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Button { store.revealCurrentProject() } label: {
                Label("打开项目文件夹", systemImage: "folder")
            }
            Menu {
                Button("打开 Codex 候选区", systemImage: "folder.badge.gearshape") {
                    store.revealCodexInboxDirectory()
                }
                Button("刷新 Codex", systemImage: "arrow.clockwise") {
                    Task { await store.refreshCodexInbox() }
                }
            } label: {
                Label("Codex 候选", systemImage: "sparkles.rectangle.stack")
            }
            Button { store.chooseImages() } label: {
                Label("加入图片", systemImage: "photo.badge.plus")
            }
            Button { isShowingVisualReview = true } label: {
                Label("视觉筛图", systemImage: "rectangle.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            Button {
                let ids = selectedIDs
                selectedIDs.removeAll()
                store.confirmPendingImports(ids)
            } label: {
                Label("确认导入\(selectedIDs.isEmpty ? "" : " \(selectedIDs.count) 项")", systemImage: "tray.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty || store.isImporting)
        }
        .padding(18)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            TextField("搜索文件名或原路径…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 310)
            Picker("资产类型", selection: $typeFilter) {
                Text("全部类型").tag(nil as AssetType?)
                ForEach(AssetType.allCases) { type in Text(type.rawValue).tag(type as AssetType?) }
            }
            .frame(width: 150)
            Picker("来源", selection: $sourceFilter) {
                ForEach(PendingImportSourceFilter.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .frame(width: 130)
            Picker("清晰度", selection: $resolutionFilter) {
                ForEach(resolutionOptions, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 150)
            Spacer()
            if !selectedIDs.isEmpty {
                Button("取消选择") { selectedIDs.removeAll() }.buttonStyle(.borderless)
                Button(role: .destructive) {
                    let ids = selectedIDs
                    selectedIDs.removeAll()
                    store.discardPendingImports(ids)
                } label: {
                    Label("移出待导入", systemImage: "xmark.circle")
                }
            }
            Button("全选当前筛选") { selectedIDs = Set(filteredItems.map(\.id)) }
                .disabled(filteredItems.isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.bar)
    }

    private func pendingRow(_ item: PendingImportItem) -> some View {
        HStack(spacing: 14) {
            Button {
                if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                else { selectedIDs.insert(item.id) }
            } label: {
                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedIDs.contains(item.id) ? "取消选择" : "选择")

            Button { preview(item) } label: {
                AssetThumbnail(asset: item.previewAsset, size: CGSize(width: 92, height: 66), contentMode: .fit)
                    .frame(width: 92, height: 66)
            }
            .buttonStyle(.plain)
            .help("查看高清原图")

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Label(item.resolutionLabel, systemImage: "sparkles.rectangle.stack")
                    Text(item.dimensionText)
                    Text(item.originalFilename)
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text(item.originalSourcePath)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let evidence = item.filenameClassificationEvidence, !evidence.isEmpty {
                    Label("名称识别：\(item.suggestedType.rawValue) · \(evidence.joined(separator: " / "))", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                PendingLocalClassificationBadge(item: item)
                if let provenance = item.generationProvenance {
                    Label(
                        "\(provenance.taskTitle) · 批次 \(provenance.batchID) · 候选 \(provenance.candidateIndex)",
                        systemImage: "sparkles"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text("导入类型").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: pendingTypeBinding(item.id)) {
                    ForEach(AssetType.allCases) { type in Text(type.rawValue).tag(type) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
        .padding(.vertical, 5)
    }

    private func pendingTypeBinding(_ id: String) -> Binding<AssetType> {
        Binding(
            get: { store.pendingImports.first(where: { $0.id == id })?.suggestedType ?? .unclassified },
            set: { store.updatePendingImport(id, type: $0) }
        )
    }

    private func preview(_ item: PendingImportItem) {
        AssetPreviewWindowController.shared.show(asset: item.previewAsset)
    }
}
