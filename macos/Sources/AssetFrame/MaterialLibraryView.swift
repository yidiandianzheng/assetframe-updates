import SwiftUI

struct MaterialLibraryView: View {
    @ObservedObject var store: GlobalMaterialStore
    let project: ProjectRecord
    let addAsCandidate: (MaterialRecord) -> Void
    @State private var filter = MaterialSearchFilter()
    @State private var records: [MaterialRecord] = []
    @State private var selection: Set<String> = []
    @State private var focusedID: String?
    @State private var presetName = ""
    @State private var batchTag = ""
    @State private var showFilters = false
    @State private var showResults = false
    @State private var showLink = false
    @State private var linkText = ""
    @FocusState private var searchFocused: Bool
    private var selectedMaterial: MaterialRecord? { records.first { $0.id == focusedID } }
    private var queryIdentity: QueryIdentity { QueryIdentity(filter: filter, projectID: project.id, revision: store.revision) }
    private struct QueryIdentity: Hashable { var filter: MaterialSearchFilter; var projectID: String; var revision: Int }

    private var workspaceBody: some View {
        VStack(spacing: 0) {
            toolbar
            if showFilters { filters.padding(10) }
            if let error = store.persistenceError {
                HStack { Text(error).foregroundStyle(.orange); Button("重新读取") { store.retryLoad() }; Button("恢复备份…") { store.chooseRestore() } }.padding(10)
            }
            if !selection.isEmpty { batchBar }
            Divider()
            if store.isLoading { ProgressView("读取素材总库…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if records.isEmpty {
                QueryAwareEmptyState(kind: store.materials.isEmpty ? .emptyLibrary : filter.search.isEmpty ? .noFilterResults : .noSearchResults, clearQuery: { filter = MaterialSearchFilter() })
            } else {
                HStack(spacing: 0) {
                    NativeMaterialGallery(records: records, selectedIDs: selection, actionContext: "\(project.id)|\(store.canWrite)") { material in
                        card(material)
                    }.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    if let material = selectedMaterial {
                        VStack(spacing: 0) {
                            HStack {
                                Button("上一项", systemImage: "chevron.left") { navigate(-1) }
                                Spacer()
                                Button("下一项", systemImage: "chevron.right") { navigate(1) }
                            }.padding(8)
                            MaterialProductionInspector(store: store, material: material, project: project)
                                .id(material.id + project.id)
                        }.frame(width: 360)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let toast = store.toast { Text(toast).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(6) }
        }
    }

    var body: some View {
        workspaceBody
        .task(id: queryIdentity) {
            let identity = queryIdentity, materials = store.materials, links = store.links
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { GlobalMaterialStore.query(materials, links: links, filter: identity.filter, projectID: identity.projectID) }.value
            guard !Task.isCancelled else { return }
            records = result
            let visible = Set(result.map(\.id)); selection.formIntersection(visible)
            if let focusedID, !visible.contains(focusedID) { self.focusedID = nil }
        }
        .onChange(of: project.id) { _, _ in selection.removeAll(); focusedID = nil; MaterialPlaybackController.shared.stop() }
        .onDisappear { MaterialPlaybackController.shared.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .previewSelectedAsset)) { _ in
            guard let selectedMaterial else { return }
            if selectedMaterial.kind == .audio || selectedMaterial.kind == .video { MaterialPlaybackController.shared.toggle() }
            else { MaterialQuickLookController.shared.show(selectedMaterial) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rateSelectedAssets)) { notification in
            if let rating = notification.userInfo?["rating"] as? Int { store.rate(selection, rating: rating, project: project) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusWorkspaceSearch)) { _ in searchFocused = true }
        .alert("加入来源链接", isPresented: $showLink) {
            TextField("https://…", text: $linkText)
            Button("加入") { store.addLink(linkText); linkText = "" }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showResults) {
            VStack {
                Text("本次导入结果").font(.headline)
                List(store.importResults) { result in VStack(alignment: .leading) { Text(result.path).lineLimit(1).truncationMode(.middle); Text(result.message).font(.caption).foregroundStyle(.secondary) } }
                Button("关闭") { showResults = false }.keyboardShortcut(.cancelAction)
            }.padding().frame(width: 650, height: 450)
        }
    }
    private var toolbar: some View {
        ContextualWorkspaceToolbar(searchContext: .materials) {
            HStack {
                Text("素材总库").font(.headline)
                TextField("搜索名称、标签、备注、用途", text: $filter.search).textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityIdentifier("assetframe.workspace-search.materials")
                Button("筛选", systemImage: "line.3.horizontal.decrease.circle") { showFilters.toggle() }
                Button("导入…", systemImage: "plus") { store.chooseFiles() }.disabled(!store.canWrite || store.isImporting)
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("导入音频…") { store.chooseAudioFiles() }.disabled(!store.canWrite || store.isImporting)
                    Button("加入链接…") { showLink = true }.disabled(!store.canWrite)
                    Button("查看导入结果") { showResults = true }
                    Button("导出当前项目选用素材…") { store.chooseDelivery(project: project) }.disabled(!store.canWrite)
                    Button("备份素材总库…") { store.chooseBackup() }.disabled(!store.canWrite)
                    Button("恢复素材库备份…") { store.chooseRestore() }.disabled(store.isImporting || store.isLoading)
                    Button("补齐五星 / 通用 SSD 副本") { store.retryManagedCopies(project: project) }.disabled(!store.canWrite)
                }
            }.padding(8)
        }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MaterialKindFilterButton(
                    selectedKinds: $filter.kinds,
                    selectedFormats: $filter.formats,
                    counts: Dictionary(grouping: store.materials, by: \.kind).mapValues(\.count)
                )
                FileFormatFilterButton(selectedFormats: $filter.formats, counts: formatCounts)
                Toggle("仅当前项目", isOn: $filter.projectOnly)
                Toggle("仅通用资产", isOn: $filter.commonOnly)
                Picker("用途", selection: $filter.purpose) { Text("全部").tag("全部"); ForEach(MaterialProductionInspector.purposes, id: \.self) { Text($0) } }.frame(maxWidth: 200)
                Picker("最低评分", selection: $filter.minimumRating) { ForEach(0...5, id: \.self) { Text($0 == 0 ? "不限评分" : "\($0) 星") } }.frame(maxWidth: 160)
            }
            HStack {
                TextField("最短秒", value: $filter.minimumDuration, format: .number).frame(width: 90)
                TextField("最长秒", value: $filter.maximumDuration, format: .number).frame(width: 90)
                Picker("比例", selection: $filter.orientation) { ForEach(["全部", "横屏", "竖屏", "方形"], id: \.self) { Text($0) } }.frame(width: 150)
                Picker("最长边", selection: $filter.minimumPixels) { Text("不限尺寸").tag(0); Text("≥ 1080").tag(1080); Text("≥ 1920").tag(1920); Text("≥ 3840").tag(3840) }.frame(width: 160)
                Button("清空筛选") { filter = MaterialSearchFilter() }
            }
            HStack {
                TextField("筛选组合名称", text: $presetName).frame(width: 170)
                Button("保存组合") { store.savePreset(name: presetName, filter: filter); presetName = "" }.disabled(!store.canWrite || presetName.isEmpty)
                Menu("已存组合") { ForEach(store.presets) { preset in Button(preset.name) { filter = preset.filter } } }
            }.textFieldStyle(.roundedBorder)
        }.font(.caption)
    }
    private var formatCounts: [String: Int] { store.materials.reduce(into: [:]) { $0[($1.originalFilename as NSString).pathExtension.lowercased(), default: 0] += 1 } }
    private var batchBar: some View {
        HStack {
            Text("已选 \(selection.count) 项")
            Button("全选结果") { selection = Set(records.map(\.id)) }
            Menu("评分") { ForEach(0...5, id: \.self) { rating in Button("\(rating) 星") { store.rate(selection, rating: rating, project: project) } } }
            Menu("审核") { ForEach(MaterialProductionInspector.reviews, id: \.self) { review in Button(review) { store.batchUpdate(selection) { var p = $0.production ?? MaterialProductionMetadata(); p.review = review; $0.production = p } } } }
            TextField("批量加标签", text: $batchTag).frame(width: 120)
            Button("添加标签") { let tag = batchTag.trimmingCharacters(in: .whitespacesAndNewlines); if !tag.isEmpty { store.batchUpdate(selection) { if !$0.tags.contains(tag) { $0.tags.append(tag) } } }; batchTag = "" }
            Button("加入通用") { store.makeCommon(selection, project: project) }
            Button("清除选择") { selection.removeAll() }
        }.font(.caption).padding(8).disabled(!store.canWrite)
    }
    private func card(_ material: MaterialRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MaterialThumbnailView(material: material).frame(height: 128)
            HStack {
                Text(material.name).lineLimit(1)
                Spacer(minLength: 4)
                if material.rating > 0 { Text("★\(material.rating)").font(.caption) }
            }
            Text("\(material.production?.purpose ?? material.kind.rawValue) · \(material.production?.review ?? "待审核")").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("预览") { select(material.id, extend: false) }
                if material.kind == .image { Button("作为图片候选") { addAsCandidate(material) } }
                Button("加入项目") { store.setLink(materialID: material.id, projectID: project.id, use: .candidate) }
            }.font(.caption).buttonStyle(.borderless).disabled(!store.canWrite)
        }
        .padding(8)
        .background(selection.contains(material.id) ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection.contains(material.id) ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { select(material.id, extend: NSEvent.modifierFlags.contains(.command)) }
        .contextMenu {
            Button("在 Finder 中显示") { if let location = material.fileLocation { store.reveal(location) } }
            Button("复制路径") { if let location = material.fileLocation { store.copyPath(location) } }
            Button("系统预览") { MaterialQuickLookController.shared.show(material) }
            Button("重新定位原文件") { store.relocate(material.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(material.name)，\(material.kind.rawValue)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "选择素材") { select(material.id, extend: false) }
        .accessibilityAction(named: "预览素材") { select(material.id, extend: false) }
    }
    private func navigate(_ delta: Int) {
        guard let focusedID, let index = records.firstIndex(where: { $0.id == focusedID }), records.indices.contains(index + delta) else { return }
        select(records[index + delta].id, extend: false)
    }
    private func select(_ id: String, extend: Bool) {
        if extend { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
        else { selection = [id] }
        focusedID = id
    }
}
