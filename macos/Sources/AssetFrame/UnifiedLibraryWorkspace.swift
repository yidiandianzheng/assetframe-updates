import SwiftUI
import AppKit

struct UnifiedLibraryWorkspace: View {
    @ObservedObject var session: LibrarySession
    @StateObject private var editGuard = InspectorEditGuard()
    @State private var showLibraryPanel = false
    @State private var librarySearch = ""
    @State private var showFeatures = false
    @State private var showUpdateLog = false
    @State private var confirmLibraryRemoval = false
    @State private var showLibraryManager = false
    @State private var projectManagement: ProjectManagementRoute?
    @State private var pendingProjectManagement: ProjectManagementRoute?
    @State private var showCacheManager = false
    @State private var showMaintenance = false
    var body: some View {
        VStack(spacing: 0) {
            if let store = session.store {
                if session.product == .story, let workspace = session.projectWorkspace {
                    ProjectWorkspaceView(session: session, service: workspace, materials: store,
                        showLibraryManager: $showLibraryManager, showLibraryPanel: $showLibraryPanel, projectManagement: $projectManagement, standalone: true)
                } else {
                    UnifiedMaterialBrowser(session: session, store: store, showLibraryPanel: $showLibraryPanel).id(session.descriptor?.id)
                }

            } else {
                VStack(spacing: 16) {
                    if session.busy { ProgressView(session.stage) }
                    Text("资源库包含图片、音频、视频和文件夹")
                    HStack { Button("打开资源库…", action: { editGuard.request { session.chooseOpen() } }); Button("创建资源库…", action: { editGuard.request { session.chooseCreate() } }) }
                    Button("资源库存储管理…") { showLibraryManager = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = session.error {
                HStack {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    Button("重新连接") { if let root = session.root { Task { await session.open(root) } } else { Task { await session.retryStart() } } }
                    Button("重新定位…", action: { editGuard.request { session.chooseOpen() } })
                    Button("关闭提示") { session.error = nil }
                }.font(.caption).padding(10)
            }
        }
        .environmentObject(editGuard)
        .popover(isPresented: $showLibraryPanel) { libraryPanel }
        .sheet(isPresented: $showLibraryManager, onDismiss: {
            projectManagement = pendingProjectManagement
            pendingProjectManagement = nil
        }) {
            LibraryManagerView(session: session, onClose: { showLibraryManager = false }, onProject: { destination in
                pendingProjectManagement = destination
                showLibraryManager = false
            })
                .environmentObject(editGuard)
        }
        .sheet(isPresented: $showCacheManager) { PreviewCacheManagerView(session: session) }
        .sheet(isPresented: $showMaintenance) { MaterialLibraryMaintenanceView(session: session) }
        .sheet(isPresented: $editGuard.needsDecision) {
            VStack(alignment: .leading, spacing: 16) {
                Text("保存对素材的修改？").font(.headline)
                Text("当前详情有未保存的修改。保存成功后才会继续操作。")
                if let error = editGuard.error { Text(error).foregroundStyle(.orange) }
                HStack {
                    Button("取消", role: .cancel) { editGuard.cancel() }
                    Button("放弃修改", role: .destructive) { editGuard.discardAndContinue() }
                    Spacer()
                    Button(editGuard.isSaving ? "正在保存…" : "保存并继续") { Task { await editGuard.saveAndContinue() } }
                        .keyboardShortcut(.defaultAction)
                }.disabled(editGuard.isSaving)
            }.padding(24).frame(width: 440).interactiveDismissDisabled()
        }
        .frame(minWidth: 820, minHeight: 580)
        .task { await session.start() }
        .sheet(isPresented: $showFeatures) { FeatureStatusView(onClose: { showFeatures = false }) }
        .sheet(isPresented: $showUpdateLog) { UpdateLogSheet(onClose: { showUpdateLog = false }) }
        .onReceive(NotificationCenter.default.publisher(for: .showFeatureStatus)) { _ in showFeatures = true }
        .onReceive(NotificationCenter.default.publisher(for: .showUpdateLog)) { _ in showUpdateLog = true }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFolder)) { _ in
            editGuard.request { if session.product == .story { projectManagement = .create } else { session.chooseOpen() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageStoryProjects)) { note in
            guard session.product == .story else { return }
            editGuard.request { projectManagement = note.userInfo?["action"] as? String == "create" ? .create : .manage }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importAssetImages)) { _ in session.chooseImport() }
        .onReceive(NotificationCenter.default.publisher(for: .linkMaterialFolder)) { _ in session.chooseImport() }
        .sheet(isPresented: Binding(get: { session.mergeReport != nil }, set: { if !$0 { session.mergeReport = nil } })) {
            if let report = session.mergeReport {
                VStack(alignment: .leading, spacing: 16) {
                    Text("合并资源库摘要").font(.title2)
                    Text("新增 \(report.added) 项 · 复用 \(report.reused) 项 · 字段冲突 \(report.conflicts) 项 · 新增项目 \(report.groups) 个")
                    Text("冲突记录将独立保留。来源库和原文件不变；目标库先备份再合并。")
                    HStack { Button("取消") { session.mergeReport = nil }; Button("确认合并") { Task { await session.commitMerge() } }.disabled(session.busy) }
                }.padding(24).frame(width: 570)
            }
        }
    }
    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索资源库…", text: $librarySearch).textFieldStyle(.roundedBorder)
            ForEach(session.registry.locations.filter { librarySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(librarySearch) }) { item in
                Button {
                    editGuard.request { showLibraryPanel = false; Task { await session.open(URL(fileURLWithPath: item.path)) } }
                } label: {
                    HStack {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) { Text(item.name); Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer(); if item.id == session.descriptor?.id { Image(systemName: "checkmark") }
                    }
                }.buttonStyle(.plain)
            }
            Divider()
            Button("资源库存储管理…", systemImage: "externaldrive.badge.gearshape") {
                showLibraryPanel = false
                editGuard.request { showLibraryManager = true }
            }
            Button("创建资源库…", systemImage: "plus.rectangle.on.folder", action: { editGuard.request { session.chooseCreate() } })
            Button("打开其他资源库…", systemImage: "folder", action: { editGuard.request { session.chooseOpen() } })
            Button("清除缓存并重新加载", systemImage: "arrow.clockwise") { editGuard.request { Task { await session.clearCache() } } }.disabled(session.store == nil || session.busy)
            Button("定位、相似素材与整理恢复…", systemImage: "wrench.and.screwdriver") { showLibraryPanel = false; editGuard.request { showMaintenance = true } }.disabled(session.store == nil || session.busy)
            Button("缓存管理与诊断…", systemImage: "internaldrive") { showLibraryPanel = false; editGuard.request { showCacheManager = true } }.disabled(session.store == nil || session.busy)
            Button("合并其他资源库…", systemImage: "arrow.triangle.merge", action: session.chooseMerge).disabled(session.store == nil || session.busy)
            if let root = session.root {
                Button("在 Finder 中显示资源库") { NSWorkspace.shared.selectFile(root.path, inFileViewerRootedAtPath: root.deletingLastPathComponent().path) }
                Button("移除当前资源库登记…", systemImage: "trash", role: .destructive) {
                    confirmLibraryRemoval = true
                }
                .confirmationDialog(
                    "从列表删除“\(session.descriptor?.name ?? "当前资源库")”？",
                    isPresented: $confirmLibraryRemoval,
                    titleVisibility: .visible
                ) {
                    Button("移除登记", role: .destructive) {
                        editGuard.request {
                            showLibraryPanel = false
                            Task { await session.removeCurrentLibrary() }
                        }
                    }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("只移除软件中的资源库登记。资源库文件、数据库、标签、备注和原始素材都会保留，之后可通过“打开资源库”重新添加。")
                }
            }
        }.buttonStyle(.borderless).padding(18).frame(width: 430)
    }
}

struct UnifiedMaterialBrowser: View {
    @ObservedObject var session: LibrarySession
    @ObservedObject var store: GlobalMaterialStore
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @EnvironmentObject private var localCLI: LocalCLIService
    @State private var cliNavigationOwner = UUID()
    @Binding var showLibraryPanel: Bool
    @State private var recordsRevision: UInt64 = 0
    @State private var textSearchCache = MaterialTextSearchCache()
    @State private var textSearchDiagnostics = MaterialTextSearchCache.Diagnostics()
    @State private var renderedNavigationIdentity = ""
    @State private var candidateQueryKey = ""
    @State private var publishedPresentationKey = ""
    @State private var queryStartedAt: UInt64 = 0
    @State private var lastRequestedSearch: String?
    @State private var queryGeneration: UInt64 = 0
    @State private var presentationGeneration: UInt64 = 0
    @State private var querying = false
    @State private var records: [MaterialRecord] = []
    @State private var resultFileSize: Int64 = 0
    @State private var resultUnknownSizeCount = 0
    @State private var recordsByID: [String: MaterialRecord] = [:]
    @State private var formatCandidates: [MaterialRecord] = []
    @State private var formatCounts: [String: Int] = [:]
    @State private var candidateRevision = 0
    @State private var selectionAnchorID: String?
    @State private var preview = false
    @State private var previewDirection = 1
    @State private var deletionIDs: Set<String> = []
    @State private var confirmDeletion = false
    @State private var usageDraft: MaterialUsageDraft?
    @State private var comparison: MaterialComparisonSelection?
    @State private var showIntelligence = false
    @State private var showTagging = false
    @State private var filters = false
    @State private var batchTag = ""
    @State private var presetName = ""
    private var feedback: Bool { session.browse.regionMarkers ?? false }
    @State private var showNotes = false
    @State private var noteDraft = ""
    @State private var notes: [String] = []
    @State private var receiving = false
    @State private var displayPopover = false
    @State private var galleryRefreshIdentity: UInt64 = 0
    @State private var sourceStatuses: [String: MaterialSourceAvailability] = [:]
    @State private var sourceStatusRevision: UInt64 = 0
    @State private var sourceScanRequest: UInt64 = 0
    @State private var linkedFolderReadRequest: UInt64 = 0
    @State private var folderEventCount = 0
    @State private var folderScanCount = 0
    @State private var folderEventsWatching = false
    @State private var linkedFolderUpdates = LinkedFolderUpdates()
    @State private var dismissedFolderUpdates = ""
    @State private var readingFolderUpdates = false
    @State private var missingSourceCount = 0
    @State private var checkingSources = false
    @State private var searchScopePopover = false
    private var display: LibraryDisplayOptions { session.browse.display ?? LibraryDisplayOptions() }
    private var displayBinding: Binding<LibraryDisplayOptions> {
        Binding(get: { display }, set: { value in editGuard.request { session.browse.display = value } })
    }
    private func guarded<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            editGuard.request { binding.wrappedValue = value }
        })
    }
    @FocusState private var searchFocused: Bool
    private var focused: MaterialRecord? { session.browse.focused.flatMap { recordsByID[$0] } }
    /// Five-star/common managed copies are organized by library now that the
    /// user-facing project-group layer has been removed.
    private var libraryContext: ProjectRecord {
        ProjectRecord(
            id: session.descriptor?.id ?? "library",
            name: session.descriptor?.name ?? "素材总库",
            rootPath: session.root?.path ?? "",
            databasePath: "",
            isLegacy: false,
            lastOpenedAt: .now
        )
    }
    private var queryKey: String {
        var facet = session.browse.filter; facet.formats = []
        let order = session.browse.sortOrder ?? MaterialSortOrder()
        let dataRevision = store.browseQueryRevision(scope: session.browse.scope, sortField: order.field)
        return "sources:\(sourceStatusRevision)|\(dataRevision)|\(session.browse.scope)|\(session.browse.search)|\(String(describing: facet))|\(display.includeSubfolders)"
    }
    /// User navigation changes start at the first matching item. Store revisions
    /// stay out of this key so imports and background metadata do not jump the gallery.
    private var galleryNavigationIdentity: String {
        let order = session.browse.sortOrder ?? MaterialSortOrder()
        return "\(session.browse.scope)|\(session.browse.search)|\(LibraryScrollAnchor.filterIdentity(session.browse.filter))|subfolders:\(display.includeSubfolders)|\(order.field.rawValue)|\(order.ascending)|\(order.randomSeed ?? 0)"
    }
    private var galleryCardContextIdentity: String {
        "\(session.descriptor?.id ?? "")|\(store.canWrite)|refresh:\(galleryRefreshIdentity)|source-status:\(sourceStatusRevision)|\(display.galleryCardPresentationIdentity)"
    }
    private var layout: some View {
        VStack(spacing: 0) {
            toolbar
            linkedFolderUpdateBanner
            HSplitView {
                if display.showSidebar { sidebar.frame(minWidth: 185, idealWidth: 225, maxWidth: 310) }
                center.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                if display.showInspector { inspector.frame(minWidth: 245, idealWidth: 300, maxWidth: 390).disabled(session.busy) }
            }
            if store.importProgressVisible || receiving { MaterialImportProgressCard(store: store, receivingDrop: receiving).padding(8) }
            if let job = store.resumableImport, !store.isImporting {
                HStack {
                    Label("待恢复的导入 · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock.arrow.circlepath")
                    Text("任务 \(job.id.uuidString.prefix(8))").foregroundStyle(.secondary)
                    Spacer()
                    Button("继续此任务") { store.resumeImport() }
                }.font(.callout).padding(8)
            }
        }
    }
    private var loadingContent: some View {
        layout
        .environment(\.fileImportDropHandler, { urls in session.importURLs(urls) })
        .onDrop(of: [.fileURL], isTargeted: $receiving, perform: acceptDrop)
        .task(id: sourceScanRequest) { await checkSourceAvailability() }
        .task(id: linkedFolderMonitorKey) { await monitorLinkedFolders() }
        .onChange(of: session.switchToken) { _, _ in
            linkedFolderUpdates = LinkedFolderUpdates()
            dismissedFolderUpdates = ""
            readingFolderUpdates = false
        }
        .onChange(of: store.isImporting) { old, active in
            if old && !active { linkedFolderReadRequest &+= 1 }
        }
        .task(id: queryKey) { await query() }
        .task(id: presentationKey) { await sortAndFilter() }
        .task(id: preview ? session.browse.focused : nil) { await prefetchNeighbors() }
    }
    private var eventContent: some View {
        loadingContent
        .onReceive(NotificationCenter.default.publisher(for: .toggleAssetSidebar)) { _ in displayBinding.showSidebar.wrappedValue.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .undoMaterialEdit)) { _ in editGuard.request { Task { _ = await store.undoEdit() } } }
        .onReceive(NotificationCenter.default.publisher(for: .redoMaterialEdit)) { _ in editGuard.request { Task { _ = await store.undoEdit(redo: true) } } }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAssetInspector)) { _ in displayBinding.showInspector.wrappedValue.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .previewSelectedAsset)) { _ in if focused != nil { preview.toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: .focusWorkspaceSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .scanCurrentProject)) { _ in scan() }
        .onReceive(NotificationCenter.default.publisher(for: .exportAssetCSV)) { _ in exportCSV() }
        .onReceive(NotificationCenter.default.publisher(for: .showAssetLibrary)) { _ in changeBrowseScope("all") }
        .onReceive(NotificationCenter.default.publisher(for: .showMaterialLibrary)) { _ in changeBrowseScope("all") }
        .onReceive(NotificationCenter.default.publisher(for: .showAssetTrash)) { _ in editGuard.request { session.browse.scope = "trash" } }
        .onReceive(NotificationCenter.default.publisher(for: .showExportLibrary)) { _ in editGuard.request { session.browse.scope = "export" } }
        .onReceive(NotificationCenter.default.publisher(for: .rateSelectedAssets)) { notification in
            receiveRating(notification)
        }
    }
    private func receiveRating(_ notification: Notification) {
        guard !session.busy, let rating = notification.userInfo?["rating"] as? Int else { return }
        store.rate(session.browse.selected, rating: rating, project: libraryContext)
    }
    var body: some View {
        eventContent
        .overlay(alignment: .bottom) {
            if let message = store.toast, !message.isEmpty {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .onChange(of: store.toast) { _, message in
            guard let message else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                if store.toast == message { store.toast = nil }
            }
        }
        .onChange(of: session.browse.scope) { _, _ in selectionAnchorID = nil; preview = false; session.browse.selected = []; session.browse.focused = nil; MaterialPlaybackController.shared.stop() }
        .onAppear { localCLI.registerNavigation(owner: cliNavigationOwner, handler: handleCLINavigation) }
        .onDisappear {
            localCLI.unregisterNavigation(owner: cliNavigationOwner)
            try? session.saveBrowse(); MaterialPlaybackController.shared.stop()
        }
        .sheet(isPresented: $showTagging) {
            MaterialTaggingWorkspace(store: store, scopeIDs: taggingScopeIDs, selectedIDs: session.browse.selected, onClose: { showTagging = false })
        }
        .sheet(isPresented: $showIntelligence) {
            MaterialIntelligenceView(store: store, scopeIDs: Set(records.map(\.id)), selectedIDs: session.browse.selected, onClose: { showIntelligence = false })
        }
        .sheet(isPresented: $showNotes) { notesPanel }
        .sheet(item: $usageDraft) { draft in
            MaterialUsageEditor(store: store, project: libraryContext, draft: draft, onClose: { usageDraft = nil })
        }
        .sheet(item: $comparison) { selection in
            MaterialComparisonView(store: store, ids: selection.ids, onClose: { comparison = nil })
        }
        .alert("删除记录及原文件？", isPresented: $confirmDeletion) {
            Button("取消", role: .cancel) { deletionIDs = [] }
            Button("删除记录及原文件", role: .destructive) {
                let ids = deletionIDs; deletionIDs = []
                Task { await session.deleteTrashedMaterials(ids) }
            }
        } message: {
            Text("将删除 \(deletionIDs.count) 条素材记录及其项目引用，原文件送入 macOS 废纸篓。其他资源库或软件若引用这些文件，也会受影响。历史版本和其他来源文件不自动删除。")
        }
        .task {
            if let root = session.root { notes = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("optimization-notes-v2.json")))) ?? [] }
        }
    }
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let token = session.switchToken
        Task {
            var urls: [URL] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in continuation.resume(returning: data) }
                }
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { urls.append(url) }
            }
            guard token == session.switchToken else { return }
            session.importURLs(urls)
        }
        return true
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
                Button { showLibraryPanel.toggle() } label: {
                    Label(session.descriptor?.name ?? "资源库", systemImage: "externaldrive")
                        .lineLimit(1).truncationMode(.middle)
                }.help(session.root?.path ?? "打开资源库").frame(maxWidth: 190)

                Picker("浏览方式", selection: guarded($session.browse.table)) { Text("画册").tag(false); Text("表格").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
                HStack(spacing: 5) {
                    Button("搜索范围", systemImage: "magnifyingglass") { searchScopePopover.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("选择搜索范围")
                        .popover(isPresented: $searchScopePopover) { searchScopePanel }
                    TextField("搜索素材…", text: guarded($session.browse.search))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !session.browse.search.isEmpty {
                        Button("清除搜索", systemImage: "xmark.circle.fill") { editGuard.request { session.browse.search = "" } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                if session.product == .assets {
                    Button("标签与分类", systemImage: "tag") { editGuard.request { showTagging = true } }.disabled(session.busy || session.browse.scope == "trash")
                }
                Button("智能整理", systemImage: "sparkles") { editGuard.request { showIntelligence = true } }.disabled(session.busy || session.browse.scope == "trash")
                Button("导入", systemImage: "plus", action: session.chooseImport).buttonStyle(.borderedProminent).disabled(store.isImporting || session.busy)
                Menu("更多", systemImage: "ellipsis.circle") {
                    fileButtons
                    Divider()
                    feedbackButtons
                }.fixedSize()
                if session.busy { ProgressView().controlSize(.small).help(session.stage) }
        }.padding(10)
    }
    private var searchScopePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索范围").font(.headline)
                Spacer()
                Button("全部") { editGuard.request { session.browse.filter.searchFields = nil } }
                    .disabled(activeSearchFields.count == MaterialSearchField.allCases.count)
            }
            Divider()
            ForEach(MaterialSearchField.allCases) { field in
                Toggle(isOn: searchFieldBinding(field)) {
                    Label(field.title, systemImage: field.systemImage)
                }
            }
            Divider()
            Text("多个关键词用空格分开，全部关键词都命中才显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 280)
    }
    private var activeSearchFields: Set<MaterialSearchField> {
        session.browse.filter.searchFields ?? Set(MaterialSearchField.allCases)
    }
    private func searchFieldBinding(_ field: MaterialSearchField) -> Binding<Bool> {
        Binding(
            get: { activeSearchFields.contains(field) },
            set: { enabled in
                var fields = activeSearchFields
                if enabled {
                    fields.insert(field)
                } else if fields.count > 1 {
                    fields.remove(field)
                }
                let updatedFields = fields == Set(MaterialSearchField.allCases) ? nil : fields
                editGuard.request { session.browse.filter.searchFields = updatedFields }
            }
        )
    }
    @ViewBuilder private var actionButtons: some View { feedbackButtons; fileButtons }
    @ViewBuilder private var feedbackButtons: some View {
        Button(feedback ? "隐藏区域标记" : "显示区域标记", systemImage: "scope") { session.browse.regionMarkers = !feedback }
        Button("优化建议（\(notes.count)）", systemImage: "note.text") { showNotes = true }
    }
    @ViewBuilder private var fileButtons: some View {
        Button("扫描文件夹", systemImage: "arrow.clockwise", action: scan).disabled(scanRoots.isEmpty || store.isImporting || session.busy).help(scanRoots.isEmpty ? "当前范围没有关联文件夹" : "扫描当前范围的关联目录")
        Button("导出 CSV", systemImage: "tablecells", action: exportCSV).disabled(records.isEmpty)
        Button("交付当前资源库选用素材…", systemImage: "shippingbox") {
            editGuard.request { store.chooseDelivery(project: libraryContext, includeLibraryQueue: true) }
        }.disabled(!store.canWrite || session.busy)
        Button(store.managedCopyJobs > 0 ? "正在补齐 SSD 副本…" : "补齐五星／通用 SSD 副本") {
            store.retryManagedCopies(project: libraryContext)
        }.disabled(!store.canWrite || store.managedCopyJobs > 0 || session.busy)
    }
    private var filterBar: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("时长（秒）")
                TextField("最短", value: guarded($session.browse.filter.minimumDuration), format: .number).frame(width: 70)
                TextField("最长", value: guarded($session.browse.filter.maximumDuration), format: .number).frame(width: 70)
                Picker("分辨率", selection: guarded($session.browse.filter.minimumPixels)) {
                    Text("不限").tag(0); Text("长边 ≥ 1080").tag(1080); Text("长边 ≥ 2160").tag(2160)
                }.frame(width: 180)
            }
            HStack {
                TextField("筛选组合名称", text: $presetName).frame(width: 160)
                Button(presetSaveTitle) { store.savePreset(name: presetName, filter: session.browse.filter); presetName = "" }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canWrite)
                    .help(presetSaveTitle == "更新组合" ? "更新同名组合的筛选条件；另存请使用不同名称" : "保存当前筛选条件")
                Spacer(minLength: 0)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GraphiteTheme.toolbar)
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                scopeButton("全部素材", "all", "tray.full")
                scopeButton("未分类", "unclassified", "folder.badge.questionmark")
                scopeButton("未标签", "untagged", "tag")
                scopeButton("最近使用", "recent", "clock")
                scopeButton("通用资产", "common", "square.stack")
                scopeButton("导出", "export", "shippingbox")
                scopeButton("失联素材", "missing", "exclamationmark.triangle")
                scopeButton("回收站", "trash", "trash")
                Divider(); Text("文件夹").foregroundStyle(.secondary)
                LibraryFolderSidebar(folders: store.organization.folders, materials: store.materials,
                                     revision: store.revision, scope: Binding(get: { session.browse.scope }, set: changeBrowseScope),
                                     expandedPaths: Binding(get: {
                    session.browse.expandedFolderPaths ?? Set(store.organization.folders.map { URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path })
                }, set: { session.browse.expandedFolderPaths = $0 }))
                Button("添加文件夹…", systemImage: "folder.badge.plus", action: session.chooseImport)
                if !store.presets.isEmpty { Divider(); Text("筛选组合").foregroundStyle(.secondary) }
                ForEach(store.presets) { preset in Button(preset.name) { editGuard.request { session.browse.filter = preset.filter } } }
            }.padding(12).buttonStyle(.plain)
        }.overlay(alignment: .topLeading) { if feedback { regionBadge("导航") } }
    }
    private func changeBrowseScope(_ scope: String) {
        editGuard.request {
            if session.browse.scope == scope && (scope == "all" || scope.hasPrefix("path:")) {
                linkedFolderReadRequest &+= 1
                dismissedFolderUpdates = ""
            }
            session.browse.scope = scope
        }
    }

    private func scopeButton(_ name: String, _ scope: String, _ icon: String) -> some View {
        Button { changeBrowseScope(scope) } label: {
            Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                .background(session.browse.scope == scope ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
    }
    private var scopeTitle: String {
        if session.browse.scope.hasPrefix("path:") { return String(session.browse.scope.dropFirst(5)) }
        return ["all": "全部素材", "unclassified": "未分类", "untagged": "未标签", "recent": "最近使用", "common": "通用资产", "export": "导出", "missing": "失联素材", "trash": "回收站"][session.browse.scope] ?? "素材"
    }
    private var taggingScopeIDs: Set<String> {
        let scope = session.browse.scope
        let folderPath: String?
        if scope.hasPrefix("path:") { folderPath = String(scope.dropFirst(5)) }
        else { folderPath = store.organization.folders.first { "folder:" + $0.id == scope }?.rootPath }
        guard let folderPath else { return Set(records.map(\.id)) }
        let prefix = URL(fileURLWithPath: folderPath).standardizedFileURL.path + "/"
        return Set(store.materials.filter { $0.deletedAt == nil && ($0.sourcePath?.hasPrefix(prefix) ?? false) }.map(\.id))
    }
    private var center: some View {
        VStack(spacing: 0) {
            MaterialFilterToolbar(filter: guarded($session.browse.filter), materials: store.materials, revision: store.revision, formatCounts: formatCounts,
                                  folders: store.organization.folders, showsMore: filters, onMore: { filters.toggle() }, tagging: store.tagging)
            if filters { filterBar }
            Divider()
            if checkingSources {
                ProgressView("正在检查原文件…").controlSize(.small).padding(8)
            }
            if missingSourceCount > 0 {
                HStack {
                    Label(session.browse.scope == "missing"
                          ? "发现 \(missingSourceCount) 项失联素材；记录和标签仍保留"
                          : "当前范围已隐藏 \(missingSourceCount) 项失联素材",
                          systemImage: "exclamationmark.triangle")
                    Spacer()
                    if session.browse.scope != "missing" {
                        Button("查看失联素材") { editGuard.request { session.browse.scope = "missing" } }
                    }
                }.font(.caption).foregroundStyle(.orange).padding(8)
            }
            HStack(spacing: 10) {
                Text("\(records.count) 项").monospacedDigit()
                if !session.browse.selected.isEmpty { Text("已选 \(session.browse.selected.count) 项").monospacedDigit() }
                if querying { ProgressView().controlSize(.small).help("正在更新结果") }
                if session.browse.scope == "export" {
                    Button("交付原文件…", systemImage: "shippingbox") {
                        editGuard.request { store.chooseDelivery(project: libraryContext, includeLibraryQueue: true) }
                    }.disabled(!store.canWrite || session.busy)
                }
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    thumbnailControls
                    EmptyView()
                }
                sortMenu
                refreshGalleryButton
                displaySettingsButton
            }.font(.callout).padding(8)
            HStack {
                Label(scopeTitle, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                if !session.browse.search.isEmpty { Text("搜索：\(session.browse.search)").lineLimit(1) }
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
            ZStack {
                if session.browse.table {
                    Table(records, selection: guarded($session.browse.selected)) {
                        TableColumn("名称", value: \.name)
                        TableColumn("媒体") { Text($0.kind.rawValue) }
                        TableColumn("评分") { Text(String($0.rating)) }
                        TableColumn("标签") { Text($0.tags.joined(separator: "、")) }
                    }.contextMenu(forSelectionType: String.self) { ids in
                        if let material = records.first(where: { ids.contains($0.id) }) {
                            Button("复制原图", systemImage: "photo.on.rectangle") { store.copyOriginalImage(material) }
                                .disabled(material.kind != .image || material.fileLocation?.exists != true)
                            Divider()
                        }
                        trashActions(ids)
                        Button("预览素材") { if focused != nil { preview = true } }
                    } primaryAction: { ids in
                        if let id = ids.first, let material = records.first(where: { $0.id == id }) { select(material, openPreview: true) }
                    }.onChange(of: session.browse.selected) { _, value in session.browse.focused = value.sorted().first }
                } else {
                    NativeMaterialGallery(records: records, selectedIDs: session.browse.selected, actionContext: galleryCardContextIdentity, contentRevision: recordsRevision, navigationIdentity: renderedNavigationIdentity, scrollPosition: $session.browse.scrollY, scrollAnchor: $session.browse.scrollAnchor, isBrowsing: !preview, proportional: display.proportional, thumbnailSize: display.imageHeight, captionHeight: display.captionHeight, onClick: { material, modifiers, doubleClick in
                        if doubleClick && modifiers.intersection([.command, .shift]).isEmpty { select(material, openPreview: true) }
                        else { selectFromGallery(material, modifiers: modifiers) }
                    }) { material in card(material) }.allowsHitTesting(!preview).accessibilityHidden(preview)
                }
                if records.isEmpty { emptyResults }
                if preview, let material = focused {
                    VStack(spacing: 0) {
                        HStack {
                            Button("返回画册", systemImage: "chevron.left", action: exitPreview)
                            Spacer(); Text(material.name).lineLimit(1); Spacer()
                            Button("上一项") { navigate(-1) }; Button("下一项") { navigate(1) }
                        }.padding(8)
                        if material.kind == .image && !MaterialDocumentPreview.usesDocumentPreview(material) { AssetImagePreview(asset: material.previewAsset, onClose: exitPreview).id(material.id) }
                        else if material.kind == .audio || material.kind == .video {
                            MaterialPlayerView(material: material, cacheRoot: SSDPreviewCache.directory("MediaAnalysis"), onCover: { seconds in store.update(material.id) { var p = $0.production ?? MaterialProductionMetadata(); p.coverSeconds = seconds; $0.production = p } }, onRange: { start, end in requestUsage(material.id, start: start, end: end) })
                        } else { MaterialDocumentPreview(material: material).id(material.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.background(Color(nsColor: .windowBackgroundColor))
                        .background(PreviewEscapeHandler(onExit: exitPreview, onNavigate: navigate).frame(width: 0, height: 0))
                        .onExitCommand(perform: exitPreview)
                        .onMoveCommand { direction in if direction == .left { navigate(-1) }; if direction == .right { navigate(1) } }
                }
                if session.showLoading {
                    VStack(spacing: 18) {
                        Text(session.stage).font(.headline)
                        ProgressView()
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]) {
                            ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 140) }
                        }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
                }
            }
        }.overlay(alignment: .topLeading) { if feedback { regionBadge("画册") } }
    }
    @ViewBuilder private var emptyResults: some View {
        if querying {
            ProgressView("正在查找素材…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !session.browse.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.browse.filter.activeFacetCount > 0 {
            ContentUnavailableView {
                Label("没有匹配的素材", systemImage: "magnifyingglass")
            } description: {
                Text("试试减少关键词或筛选条件，当前目录保持不变。")
            } actions: {
                if !session.browse.search.isEmpty {
                    Button("清除搜索") { editGuard.request { session.browse.search = "" } }
                }
                if session.browse.filter.activeFacetCount > 0 {
                    Button("清除筛选") { editGuard.request { session.browse.filter.resetFacets() } }
                }
            }
        } else if session.browse.scope == "trash" {
            ContentUnavailableView("回收站为空", systemImage: "trash", description: Text("移入回收站的素材会显示在这里。"))
        } else if session.browse.scope == "all" {
            ContentUnavailableView {
                Label("开始整理素材", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("拖入图片、视频、音频或文件夹，原文件保留在原位置。")
            } actions: {
                Button("导入素材…", action: session.chooseImport)
                    .disabled(store.isImporting || session.busy)
            }
        } else {
            ContentUnavailableView {
                Label("当前范围没有素材", systemImage: "folder")
            } description: {
                Text("可以切换目录，或返回全部素材继续浏览。")
            } actions: {
                Button("查看全部素材") { changeBrowseScope("all") }
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if session.browse.selected.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                Button("候选图片对比") {
                    editGuard.request {
                        comparison = MaterialComparisonSelection(ids: records.filter { session.browse.selected.contains($0.id) }.map(\.id))
                    }
                }.disabled(!(2...4).contains(session.browse.selected.count) || !records.filter { session.browse.selected.contains($0.id) }.allSatisfy { $0.kind == .image })
                Text("已选择 \(session.browse.selected.count) 项").font(.headline)
                Menu("批量评分") { ForEach(0...5, id: \.self) { n in Button("\(n) 星") { store.rate(session.browse.selected, rating: n, project: libraryContext) } } }
                MaterialBatchClassificationMenu(store: store, ids: session.browse.selected)
                TextField("添加标签", text: $batchTag)
                Button("应用标签") { let tag = batchTag.trimmingCharacters(in: .whitespacesAndNewlines); if !tag.isEmpty { store.batchUpdate(session.browse.selected) { $0.tags = Array(Set($0.tags + [tag])).sorted() } } }
                colorEditor
                trashActions(session.browse.selected)
                Button("加入通用资产") { store.makeCommon(session.browse.selected, project: libraryContext) }
                Spacer()
            }.padding()
        } else if let material = focused {
            VStack {
                if let conflict = material.migrationConflict { Text(conflict).font(.caption).foregroundStyle(.orange) }
                MaterialProductionInspector(store: store, material: material, project: libraryContext, sourceAvailability: sourceStatuses[material.id], editGuard: editGuard, onUse: { start, end in requestUsage(material.id, start: start, end: end) }, onRelocated: { refreshGallery() }).id(material.id)
                trashActions([material.id])
            }.padding(6)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("基本信息").font(.headline)
                Text("文件数：\(records.count)")
                Text("已知大小：\(ByteCountFormatter.string(fromByteCount: resultFileSize, countStyle: .file))")
                if resultUnknownSizeCount > 0 { Text("\(resultUnknownSizeCount) 项大小尚未读取").foregroundStyle(.secondary) }
                Spacer()
            }.padding()
        }
    }
    private var colorEditor: some View {
        Menu("颜色标记（手动）") {
            Button("清除颜色标记") { store.batchUpdate(session.browse.selected) { $0.colorLabel = nil } }
            ForEach(MaterialFilterToolbar.colors, id: \.self) { color in
                Button(color) { store.batchUpdate(session.browse.selected) { $0.colorLabel = color } }
            }
        }.disabled(!store.canWrite || session.browse.selected.isEmpty)
    }
    private var thumbnailControls: some View {
        HStack(spacing: 5) {
            Button("缩小缩略图", systemImage: "minus") {
                displayBinding.thumbnailSize.wrappedValue = max(LibraryDisplayOptions.minimumThumbnailSize, display.imageHeight - 24)
            }.labelStyle(.iconOnly)
            Slider(
                value: displayBinding.thumbnailSize,
                in: LibraryDisplayOptions.minimumThumbnailSize...LibraryDisplayOptions.maximumThumbnailSize,
                step: 8
            )
            .frame(width: 100)
            .accessibilityLabel("缩略图大小")
            .accessibilityValue("\(Int(display.imageHeight))")
            Button("放大缩略图", systemImage: "plus") {
                displayBinding.thumbnailSize.wrappedValue = min(LibraryDisplayOptions.maximumThumbnailSize, display.imageHeight + 24)
            }.labelStyle(.iconOnly)
        }.buttonStyle(.borderless).disabled(session.browse.table).help("调整画册缩略图大小")
    }
    private var displaySettingsButton: some View {
        Button { displayPopover.toggle() } label: { Label("显示设置", systemImage: "slider.horizontal.3") }
            .popover(isPresented: $displayPopover) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("布局方式", selection: displayBinding.proportional) {
                        Text("自适应 · 原图比例").tag(true)
                        Text("整齐方格").tag(false)
                    }
                    HStack(spacing: 8) {
                        Text("排列方式")
                        Spacer()
                        sortFieldMenu
                        sortDirectionControl
                    }
                    Divider()
                    Toggle("显示名称", isOn: displayBinding.showName)
                    Toggle("显示简介", isOn: displayBinding.showSummary)
                    Picker("简介内容", selection: displayBinding.summary) {
                        ForEach(["尺寸", "文件大小", "时长", "评分", "备注", "分类"], id: \.self) { Text($0).tag($0) }
                    }.disabled(!display.showSummary)
                    Toggle("显示扩展名", isOn: displayBinding.showExtension)
                    Toggle("显示扩展名标签", isOn: displayBinding.showExtensionBadge)
                    Toggle("显示备注数", isOn: displayBinding.showNoteCount)
                    Toggle("显示子文件夹内容", isOn: displayBinding.includeSubfolders)
                        .help("在左侧选择文件夹时，包含其下所有子文件夹素材")
                    Divider()
                    Toggle("显示检查器", isOn: displayBinding.showInspector)
                    Button("恢复默认显示") { session.browse.display = nil }
                }.toggleStyle(.switch).padding(18).frame(width: 310)
            }
    }
    private var refreshGalleryButton: some View {
        Button("刷新画册", systemImage: "arrow.clockwise", action: refreshGallery)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("检查已链接文件夹的新增和变更，提示后由你选择读取")
            .disabled(session.busy || checkingSources)
    }

    private func refreshGallery() {
        MaterialPlaybackController.shared.stop()
        PreviewImagePipeline.shared.cancelPendingAndClearMemory()
        linkedFolderReadRequest &+= 1
        dismissedFolderUpdates = ""
        sourceScanRequest &+= 1
        checkingSources = true
        galleryRefreshIdentity &+= 1
    }

    private var linkedFolderMonitorKey: String {
        store.organization.folders.map(\.rootPath).sorted().joined(separator: "|") + "|\(session.switchToken)|\(linkedFolderReadRequest)"
    }
    private var presetSaveTitle: String {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.presets.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ? "更新组合" : "保存组合"
    }
    private var linkedFolderUpdateBlockReason: String? {
        if readingFolderUpdates { return "正在读取文件夹更新，请稍候" }
        if store.isImporting { return "正在导入素材，完成或取消后可读取文件夹更新" }
        if session.busy { return "资源库操作进行中，请稍候" }
        if !store.canWrite { return store.persistenceError == nil ? "资源库正在加载，请稍候" : "资源库暂不可写入，请先处理保存或读取错误" }
        if store.resumableImport != nil { return "存在待恢复的导入，请先在窗口底部继续此任务" }
        return nil
    }
    private var linkedFolderUpdateBanner: some View {
        Group {
            if linkedFolderUpdates.hasUpdates {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Label("链接文件夹有更新：新增 \(linkedFolderUpdates.added.count) 项 · 变更 \(linkedFolderUpdates.changed.count) 项", systemImage: "folder.badge.plus")
                        Spacer()
                        if dismissedFolderUpdates == linkedFolderUpdates.signature {
                            Button("查看更新") { dismissedFolderUpdates = "" }
                        } else {
                            if !linkedFolderUpdates.added.isEmpty {
                                Button("读取新增素材") { applyFolderUpdates(changed: false) }
                                    .disabled(linkedFolderUpdateBlockReason != nil)
                                    .help(linkedFolderUpdateBlockReason ?? "读取已发现的新增素材")
                            }
                            if !linkedFolderUpdates.changed.isEmpty {
                                Button("更新已变更素材") { applyFolderUpdates(changed: true) }
                                    .disabled(linkedFolderUpdateBlockReason != nil)
                                    .help(linkedFolderUpdateBlockReason ?? "更新已发现的变更素材")
                            }
                            Button("稍后") { dismissedFolderUpdates = linkedFolderUpdates.signature }
                        }
                    }
                    if dismissedFolderUpdates != linkedFolderUpdates.signature, let reason = linkedFolderUpdateBlockReason {
                        Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }.font(.callout).padding(10).background(.regularMaterial)
            }
            if !linkedFolderUpdates.errors.isEmpty {
                DisclosureGroup("部分文件不可读 · \(linkedFolderUpdates.errors.count) 项") {
                    ForEach(Array(linkedFolderUpdates.errors.enumerated()), id: \.offset) { Text($0.element).font(.caption).textSelection(.enabled) }
                }.foregroundStyle(.orange).padding(.horizontal, 10)
            }
            if !linkedFolderUpdates.skipped.isEmpty {
                DisclosureGroup("已跳过不支持的文件 · \(linkedFolderUpdates.skipped.count) 项") {
                    ForEach(Array(linkedFolderUpdates.skipped.enumerated()), id: \.offset) { Text($0.element).font(.caption).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
        }
    }
    private func monitorLinkedFolders() async {
        let token = session.switchToken
        let monitor = LinkedFolderEventMonitor(roots: store.organization.folders.map { URL(fileURLWithPath: $0.rootPath) })
        folderEventsWatching = monitor.watching
        defer { monitor.stop(); if token == session.switchToken { folderEventsWatching = false } }
        // This task lives only while this library view is open. No indexing or
        // persistent background service runs as a consequence of detection.
        for await cause in monitor.events {
            guard !Task.isCancelled, token == session.switchToken else { return }
            if cause == .filesystem || cause == .volume { folderEventCount += 1 }
            if cause == .volume { sourceScanRequest &+= 1; PreviewImagePipeline.shared.cancelPendingAndClearMemory() }
            if !store.isImporting && !readingFolderUpdates {
                let roots = store.organization.folders.map { URL(fileURLWithPath: $0.rootPath) }
                let known = store.materials.compactMap { record -> LinkedFolderFileState? in
                    guard let path = record.sourcePath else { return nil }
                    return LinkedFolderFileState(path: path, size: record.fileSize, modified: record.sourceModifiedAt)
                }
                let worker = Task.detached(priority: .utility) { await LinkedFolderUpdateDetector.scan(roots: roots, known: known) }
                let updates = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, token == session.switchToken else { return }
                linkedFolderUpdates = updates
                folderScanCount += 1
            }
        }
    }
    private func applyFolderUpdates(changed: Bool) {
        editGuard.request {
            let urls = changed ? linkedFolderUpdates.changed : linkedFolderUpdates.added
            let directories = linkedFolderUpdates.directories
            let token = session.switchToken
            readingFolderUpdates = true
            Task {
                _ = await store.readLinkedFolders(files: urls, directories: directories)
                guard token == session.switchToken else { return }
                readingFolderUpdates = false
                dismissedFolderUpdates = ""
                linkedFolderReadRequest &+= 1
                sourceScanRequest &+= 1
            }
        }
    }

    private func checkSourceAvailability() async {
        let token = session.switchToken
        checkingSources = true
        let shouldReportResult = sourceScanRequest > 0
        let materials = store.materials
        let worker = Task.detached(priority: .utility) {
            var result: [String: MaterialSourceAvailability] = [:]
            result.reserveCapacity(materials.count)
            for material in materials where material.deletedAt == nil {
                guard !Task.isCancelled else { return result }
                result[material.id] = material.kind == .link
                    ? .available
                    : MaterialSourceAvailability.inspect(paths: [material.sourcePath] + material.sourceLocations.map(Optional.some))
            }
            return result
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, token == session.switchToken else { return }
        sourceStatuses = result
        sourceStatusRevision &+= 1
        checkingSources = false
        if shouldReportResult {
            let count = result.values.filter { $0 == .missing }.count
            store.toast = count == 0 ? "检查完成，没有失联素材" : "检查完成，发现 \(count) 项失联素材"
        }
    }
    private func fileExtension(_ m: MaterialRecord) -> String {
        URL(fileURLWithPath: m.originalFilename).pathExtension
    }
    private func displayName(_ m: MaterialRecord) -> String {
        let ext = fileExtension(m)
        guard !ext.isEmpty else { return m.name }
        let suffix = "." + ext
        let hasSuffix = m.name.lowercased().hasSuffix(suffix.lowercased())
        return display.showExtension ? (hasSuffix ? m.name : m.name + suffix) : (hasSuffix ? String(m.name.dropLast(suffix.count)) : m.name)
    }
    private func summaryText(_ m: MaterialRecord) -> String {
        if let status = sourceStatuses[m.id], status != .available { return status.rawValue }
        switch display.summary {
        case "文件大小": return m.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小待读取"
        case "时长": return m.mediaMetadata?.durationSeconds.map { String(format: "%.1f 秒", $0) } ?? "时长未知 / 不适用"
        case "评分": return "\(m.rating) 星"
        case "备注": return m.note.isEmpty ? "无备注" : m.note
        case "分类": return m.classificationDisplayText.isEmpty ? "未分类" : m.classificationDisplayText
        default:
            guard let w = m.mediaMetadata?.pixelWidth, let h = m.mediaMetadata?.pixelHeight else { return m.kind.rawValue }
            return "\(w) × \(h)"
        }
    }
    private func exitPreview() {
        preview = false
        MaterialPlaybackController.shared.pause()
    }
    private func handleCLINavigation(_ command: String, _ arguments: [String: String]) throws -> CLIValue {
        if command == "browse.status" {
            return .object(["preview": .bool(preview), "visibleCount": .number(Double(records.count)),
                            "searchIndex": try CLIValue.encoded(textSearchDiagnostics),
                            "folderEvents": .object(["watching": .bool(folderEventsWatching), "events": .number(Double(folderEventCount)), "scans": .number(Double(folderScanCount))]),
                            "queryPending": .bool(candidateQueryKey != queryKey || publishedPresentationKey != presentationKey), "inspectorDirty": .bool(editGuard.dirty),
                            "decisionPending": .bool(editGuard.needsDecision), "saving": .bool(editGuard.isSaving)])
        }
        guard !editGuard.dirty, !editGuard.isSaving, !editGuard.needsDecision else {
            throw CLIError(code: "unsaved_edits", message: "详情栏有未保存修改或待处理决定，请先在桌面端保存或取消")
        }
        if command == "browse.search" {
            guard let query = arguments["query"], query.utf8.count <= 4096 else {
                throw CLIError(code: "invalid_argument", message: "query必填，最大4096字节")
            }
            session.browse.search = query
        } else if command == "browse.check" {
            return .object(["ready": .bool(true)])
        } else if command == "browse.exit" {
            exitPreview()
        } else {
            guard let id = arguments["id"], let material = recordsByID[id] else {
                throw CLIError(code: "material_not_visible", message: "此素材不在当前筛选结果中；请先调整桌面端目录、筛选或搜索")
            }
            select(material, openPreview: command == "browse.preview")
        }
        return .object(["accepted": .bool(true), "focusedID": .optional(session.browse.focused),
                        "search": .string(session.browse.search), "preview": .bool(preview),
                        "note": .string("操作已提交，界面与媒体加载可能尚未完成；请查询status确认")])
    }

    private func card(_ m: MaterialRecord) -> some View {
        VStack(spacing: 4) {
            MaterialThumbnailView(
                material: m,
                showFormatBadge: display.showExtensionBadge && !fileExtension(m).isEmpty,
                useFileExtensionBadge: true,
                previewMaximumDimension: display.galleryPreviewMaximumDimension,
                refreshIdentity: galleryRefreshIdentity
            ).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        if display.showNoteCount, !m.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Label("1", systemImage: "text.bubble").help("1 条素材备注") }
                    }.font(.caption2).padding(3).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            if display.showName { Text(displayName(m)).lineLimit(1).font(.caption) }
            if display.showSummary { Text(summaryText(m)).lineLimit(1).font(.caption).foregroundStyle(.secondary) }
        }.padding(4).background(session.browse.selected.contains(m.id) ? Color.accentColor.opacity(0.22) : .clear)
            .clipped()
            .contentShape(Rectangle())
            .contextMenu {
                Button("复制原图", systemImage: "photo.on.rectangle") { store.copyOriginalImage(m) }
                    .disabled(m.kind != .image || m.fileLocation?.exists != true)
                Divider()
                trashActions(session.browse.selected.contains(m.id) ? session.browse.selected : [m.id])
                Divider()
                Button("在 Finder 中显示", systemImage: "folder") { if let location = m.fileLocation { store.reveal(location) } }
                Button("系统预览", systemImage: "eye") { MaterialQuickLookController.shared.show(m) }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("\(m.name)，\(m.kind.rawValue)")
            .accessibilityAction(named: "预览素材") { select(m, openPreview: true) }
    }
    @ViewBuilder private func trashActions(_ ids: Set<String>) -> some View {
        let items = store.materials.filter { ids.contains($0.id) }
        if !items.isEmpty {
            if items.allSatisfy({ $0.deletedAt != nil }) {
                Button("恢复素材", systemImage: "arrow.uturn.backward") { store.batchUpdate(ids) { $0.deletedAt = nil } }
                    .disabled(session.busy || !store.canWrite)
                Button("删除记录及原文件…", systemImage: "trash", role: .destructive) {
                    deletionIDs = ids; confirmDeletion = true
                }.disabled(session.busy || !store.canWrite || store.isImporting)
            } else {
                Button("移入回收站", systemImage: "trash") {
                    MaterialPlaybackController.shared.stop()
                    store.batchUpdate(ids) { $0.deletedAt = .now }
                }.disabled(session.busy || !store.canWrite)
            }
        }
    }
    private func requestUsage(_ id: String, start: Double? = nil, end: Double? = nil) {
        editGuard.request {
            if MaterialPlaybackController.shared.playing { MaterialPlaybackController.shared.toggle() }
            usageDraft = MaterialUsageDraft(materialID: id, inPoint: start, outPoint: end)
        }
    }
    private func selectFromGallery(_ material: MaterialRecord, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.contains(.shift) || modifiers.contains(.command) else { select(material); return }
        editGuard.request {
            guard recordsByID[material.id] != nil else { return }
            BrowsePerformanceTrace.beginSelection()
            MaterialPlaybackController.shared.stop()
            if modifiers.contains(.shift) {
                let ids = records.map(\.id)
                let anchor = selectionAnchorID.flatMap { ids.contains($0) ? $0 : nil }
                    ?? session.browse.focused
                    ?? records.first(where: { session.browse.selected.contains($0.id) })?.id
                    ?? material.id
                selectionAnchorID = anchor
                session.browse.selected = GalleryRangeSelection.ids(
                    orderedIDs: ids, anchor: anchor, clicked: material.id,
                    selected: session.browse.selected, additive: modifiers.contains(.command)
                )
            } else {
                if !session.browse.selected.insert(material.id).inserted {
                    session.browse.selected.remove(material.id)
                }
                selectionAnchorID = material.id
            }
            session.browse.focused = session.browse.selected.contains(material.id)
                ? material.id : records.first(where: { session.browse.selected.contains($0.id) })?.id
        }
    }
    private func select(_ material: MaterialRecord, openPreview: Bool = false) {
        editGuard.request {
            BrowsePerformanceTrace.beginSelection()
            if session.browse.focused != material.id {
                MaterialPlaybackController.shared.stop()
            }
            selectionAnchorID = material.id
            session.browse.selected = [material.id]
            session.browse.focused = material.id
            if openPreview {
                BrowsePerformanceTrace.beginPreview(material.id)
                preview = true
            }
            // Selection is transient; only an actual preview counts as usage.
            if openPreview { store.recordPreviewUsage(material.id) }
        }
    }
    private func navigate(_ step: Int) {
        guard let id = focused?.id, let index = records.firstIndex(where: { $0.id == id }), records.indices.contains(index + step) else { return }
        previewDirection = step < 0 ? -1 : 1
        GlobalMaterialStore.noteBrowseInteraction()
        select(records[index + step], openPreview: true)
    }
    private func prefetchNeighbors() async {
            guard preview, let id = session.browse.focused, let index = records.firstIndex(where: { $0.id == id }) else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let neighbors = [index + previewDirection, index - previewDirection].filter { records.indices.contains($0) }.map { records[$0] }
            // Match AssetImagePreview's screen target so prefetch is reusable.
            let viewportSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 820)
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2
            let worker = Task.detached(priority: .utility) {
                for m in neighbors where m.kind == .image {
                    guard !Task.isCancelled else { return }
                    guard let source = AssetStore.bestAvailableSource(for: m.previewAsset),
                          ImportResumeRecord.availableLocally(URL(fileURLWithPath: source.path)) else { continue }
                    _ = PreviewImagePipeline.shared.load(request: PreviewImageRequest(path: source.path,
                        sourceIdentity: "\(source.id)|\(source.fileSize ?? 0)", sourceWidth: source.pixelWidth,
                        sourceHeight: source.pixelHeight, priority: .utility), viewportSize: viewportSize,
                        backingScale: backingScale, fullResolution: false)
                }
            }
            await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
    private func query() async {
        let state = session.browse, items = store.materials, links = store.links, organization = store.organization, tagging = store.tagging
        let statusSnapshot = sourceStatuses
        let token = session.switchToken, requestKey = queryKey
        let cache = textSearchCache
        let indexKey = MaterialTextSearchCache.Key(libraryGeneration: token.uuidString, queryRevision: store.queryRevision,
            fields: state.filter.searchFields ?? Set(MaterialSearchField.allCases), catalogKey: tagging.catalogKey)
        queryGeneration &+= 1
        let generation = queryGeneration
        querying = true
        defer { if generation == queryGeneration { querying = false } }
        let debounce = lastRequestedSearch != nil && lastRequestedSearch != state.search
        lastRequestedSearch = state.search
        if debounce { try? await Task.sleep(for: .milliseconds(150)) }
        queryStartedAt = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled, token == session.switchToken, requestKey == queryKey else { return }
        let worker = Task.detached(priority: .userInitiated) {
            var f = state.filter; f.formats = []; f.search = state.search; f.projectOnly = false
            let exportIDs = Set(links.lazy.filter { $0.selection == "选用" }.map(\.materialID))
            let scoped = items.filter { m in
                if state.scope == "trash" { return m.deletedAt != nil }
                guard m.deletedAt == nil else { return false }
                if state.scope == "unclassified" {
                    // 旧 assetType 与新词表分类任一存在即视为已分类；旧库没有分类字段时仍显示为未分类。
                    let legacyUnclassified = m.assetType == nil || m.assetType == .unclassified
                    let vocabularyUnclassified = m.classification?.isEmpty ?? true
                    return legacyUnclassified && vocabularyUnclassified
                }
                if state.scope == "untagged" { return m.tags.isEmpty }
                if state.scope == "recent" { return m.lastUsedAt != nil }
                if state.scope == "common" { return m.production?.isCommon == true }
                if state.scope == "export" { return organization.exportNames[m.id] != nil || exportIDs.contains(m.id) }
                if state.scope.hasPrefix("path:") { let path = String(state.scope.dropFirst(5)); return (state.display ?? LibraryDisplayOptions()).contains(path: m.sourcePath, folder: path) }
                return true
            }
            let statuses = statusSnapshot
            let missingCount = scoped.filter { statuses[$0.id] == .missing }.count
            let candidates = scoped.filter { m in
                if state.scope == "trash" { return true }
                return state.scope == "missing" ? statuses[m.id] == .missing : statuses[m.id] != .missing
            }
            let searchable = state.scope == "trash" ? candidates.map { m in var value = m; value.deletedAt = nil; return value } : candidates
            let prepared = await cache.prepare(key: indexKey, enabled: !state.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                materials: items, links: links, folders: organization.folders, tagging: tagging)
            let hits = GlobalMaterialStore.query(
                searchable,
                links: links,
                filter: f,
                projectID: "",
                folders: organization.folders, sorted: false, searchIndex: prepared.index, tagging: tagging, isCancelled: { Task.isCancelled }
            )
            let originals = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            let items = hits.compactMap { originals[$0.id] }
            return (items, GlobalMaterialStore.formatCounts(in: items), statuses, missingCount, prepared.diagnostics)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, token == session.switchToken, requestKey == queryKey, generation == queryGeneration else { return }
        candidateQueryKey = requestKey
        textSearchDiagnostics = result.4
        sourceStatuses = result.2
        missingSourceCount = result.3
        formatCandidates = result.0
        formatCounts = result.1
        candidateRevision &+= 1
    }
    private var presentationKey: String {
        let order = session.browse.sortOrder ?? MaterialSortOrder()
        return "\(candidateRevision)|\(session.browse.filter.formats.sorted())|\(order.field.rawValue)|\(order.ascending)|\(order.randomSeed ?? 0)"
    }
    private func sortAndFilter() async {
        let selected = session.browse.filter.formats, candidates = formatCandidates
        let order = session.browse.sortOrder ?? MaterialSortOrder()
        guard candidateQueryKey == queryKey else { return }
        let token = session.switchToken, requestKey = queryKey, key = presentationKey
        let navigation = galleryNavigationIdentity
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let worker = Task.detached(priority: .userInitiated) {
            let filtered = selected.isEmpty ? candidates : candidates.filter {
                selected.contains(($0.originalFilename as NSString).pathExtension.lowercased())
            }
            let sorted = GlobalMaterialStore.sortedMaterials(filtered, order: order)
            let summary = sorted.reduce(into: (bytes: Int64(0), unknown: 0)) { total, material in
                if let size = material.fileSize { total.bytes += max(0, size) }
                else { total.unknown += 1 }
            }
            return (sorted, summary)
        }
        let output = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, token == session.switchToken, requestKey == queryKey,
              key == presentationKey, generation == presentationGeneration else { return }
        let result = output.0
        let publish = {
            guard token == session.switchToken, requestKey == queryKey, key == presentationKey else { return }
            records = result
            publishedPresentationKey = key
            resultFileSize = output.1.bytes
            resultUnknownSizeCount = output.1.unknown
            BrowsePerformanceTrace.emit("query_and_sort", since: queryStartedAt)
            recordsByID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        recordsRevision &+= 1
        renderedNavigationIdentity = navigation
        // A refresh/filter must never leave batch actions targeting invisible files.
        session.browse.selected.formIntersection(Set(result.map(\.id)))
        if let anchor = selectionAnchorID, recordsByID[anchor] == nil { selectionAnchorID = nil }
        if let focused = session.browse.focused, !result.contains(where: { $0.id == focused }) {
            session.browse.focused = nil
            preview = false
            MaterialPlaybackController.shared.stop()
        }
        }
        if let id = session.browse.focused, editGuard.dirty, !result.contains(where: { $0.id == id }) {
            editGuard.request(publish)
        } else { publish() }
    }
    private var sortMenu: some View {
        let order = session.browse.sortOrder ?? MaterialSortOrder()
        return Menu {
            sortMenuContent
            Divider()
            if order.field != .random {
                Button("升序 · 小到大 / 旧到新", systemImage: order.ascending ? "checkmark" : "arrow.up") {
                    setSortDirection(true)
                }
                Button("降序 · 大到小 / 新到旧", systemImage: !order.ascending ? "checkmark" : "arrow.down") {
                    setSortDirection(false)
                }
            }
        } label: {
            Label(sortMenuLabel, systemImage: order.field == .random ? "shuffle" : (order.ascending ? "arrow.up" : "arrow.down"))
        }.menuStyle(.borderlessButton).fixedSize().help("名称按自然顺序排列；未知大小、时长和分辨率始终放在最后")
    }

    private var sortFieldMenu: some View {
        Menu {
            sortMenuContent
        } label: {
            HStack(spacing: 5) {
                Text(session.browse.sortOrder?.field.rawValue ?? "使用全局设置")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .frame(minWidth: 112, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择素材排列依据")
    }

    @ViewBuilder private var sortMenuContent: some View {
        Button {
            session.browse.sortOrder = nil
        } label: {
            if session.browse.sortOrder == nil {
                Label("使用全局设置", systemImage: "checkmark")
            } else {
                Text("使用全局设置")
            }
        }
        Divider()
        Section("自定义排序") {
            ForEach(MaterialSortField.allCases) { field in
                Button {
                    setSortField(field)
                } label: {
                    if session.browse.sortOrder?.field == field {
                        Label(field.rawValue, systemImage: "checkmark")
                    } else {
                        Text(field.rawValue)
                    }
                }
            }
        }
    }

    private var sortDirectionControl: some View {
        let order = session.browse.sortOrder ?? MaterialSortOrder()
        return HStack(spacing: 1) {
            Button("升序", systemImage: "arrow.up") { setSortDirection(true) }
                .accessibilityAddTraits(order.ascending ? .isSelected : [])
            Button("降序", systemImage: "arrow.down") { setSortDirection(false) }
                .accessibilityAddTraits(!order.ascending ? .isSelected : [])
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(order.field == .random)
        .opacity(order.field == .random ? 0.45 : 1)
    }

    private var sortMenuLabel: String {
        if let order = session.browse.sortOrder { return "排序：" + order.field.rawValue }
        return "排序：全局 · " + MaterialSortOrder().field.rawValue
    }

    private func setSortField(_ field: MaterialSortField) {
        if field == .random {
            let seed = UInt64(max(0, Date.now.timeIntervalSince1970 * 1_000))
            session.browse.sortOrder = MaterialSortOrder(field: .random, ascending: true, randomSeed: seed)
            return
        }
        let defaultAscending: Bool = switch field {
        case .name, .format: true
        default: false
        }
        session.browse.sortOrder = MaterialSortOrder(field: field, ascending: defaultAscending)
    }

    private func setSortDirection(_ ascending: Bool) {
        var order = session.browse.sortOrder ?? MaterialSortOrder()
        guard order.field != .random else { return }
        order.ascending = ascending
        session.browse.sortOrder = order
    }
    private var scanRoots: [URL] {
        if session.browse.scope.hasPrefix("path:") { return [URL(fileURLWithPath: String(session.browse.scope.dropFirst(5)))] }
        return store.organization.folders.map { URL(fileURLWithPath: $0.rootPath) }
    }
    private func scan() { session.importURLs(scanRoots) }
    private func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "素材清单.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = records
        Task {
            do {
                try await Task.detached {
                    func escape(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    let body = (["ID,名称,媒体类型,评分,标签,分类,原路径"] + rows.map { [$0.id, $0.name, $0.kind.rawValue, String($0.rating), $0.tags.joined(separator: "、"), $0.classificationDisplayText, $0.sourcePath ?? $0.sourceURL ?? ""].map(escape).joined(separator: ",") }).joined(separator: "\r\n")
                    try Data(("\u{FEFF}" + body).utf8).write(to: url, options: .atomic)
                }.value
            } catch { session.error = error.localizedDescription }
        }
    }
    private func regionBadge(_ name: String) -> some View { Text(name).font(.caption2).padding(4).background(.orange).foregroundStyle(.black).allowsHitTesting(false) }
    private var notesPanel: some View {
        VStack(alignment: .leading) {
            Text("优化建议").font(.headline)
            List(notes, id: \.self) { Text($0) }
            TextEditor(text: $noteDraft).frame(height: 90)
            HStack {
                Button("保存建议") {
                    guard !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let root = session.root else { return }
                    do { let updated = notes + [noteDraft]; try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("optimization-notes-v2.json"), options: .atomic); notes = updated; noteDraft = "" }
                    catch { session.error = error.localizedDescription }
                }
                Button("关闭") { showNotes = false }
            }
        }.padding(20).frame(width: 520, height: 390)
    }
}

extension MaterialRecord {
    var previewAsset: AssetItem {
        var asset = legacyAsset ?? AssetItem(id: id, name: name, type: assetType ?? .unclassified, imagePath: sourcePath ?? "", originalFilename: originalFilename,
            decision: .pending, note: note, reuse: .b, project: "", episodes: [], candidatePlan: .none, version: production?.versionName ?? "v01", purpose: .pending,
            category: .pending, qaResult: .pending, productionStatus: .pendingAcceptance, assetDescription: "", repairReason: "", fingerprint: fingerprint,
            shapeState: "", promptSource: "", generationPlatform: "", position: CanvasPoint(x: 0, y: 0), createdAt: createdAt)
        asset.id = id; asset.name = name; asset.imagePath = sourcePath ?? ""; asset.pixelWidth = mediaMetadata?.pixelWidth; asset.pixelHeight = mediaMetadata?.pixelHeight
        asset.sourceVersions = nil
        return asset
    }
}
