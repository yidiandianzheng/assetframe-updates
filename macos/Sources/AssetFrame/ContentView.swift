import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func pendingGalleryImportID(from galleryID: String) -> String? {
    let prefix = "PENDING-"
    guard galleryID.hasPrefix(prefix) else { return nil }
    return String(galleryID.dropFirst(prefix.count))
}

private enum SidebarMode: String, CaseIterable, Identifiable {
    case folders = "文件夹"
    case library = "分类"

    var id: String { rawValue }
}

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    func values() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @StateObject private var store: AssetStore
    @StateObject private var materialStore: GlobalMaterialStore
    @StateObject private var globalFiveStarStore: GlobalFiveStarStore
    @StateObject private var optimizationNoteStore: OptimizationNoteStore
    @StateObject private var workspaceSelection = WorkspaceSelectionModel()
    @State private var savedView: SavedView = .allGallery
    @AppStorage("assetWorkspaceDestination") private var workspaceDestination: WorkspaceDestination = .assetLibrary
    @State private var search = ""
    @State private var debouncedSearch = ""
    @FocusState private var assetSearchFocused: Bool
    @State private var assetFilter = AssetFilter()
    @State private var assetSort = AssetSortConfiguration()
    @State private var isDropping = false
    @State private var receivingDrop = false
    @AppStorage("assetInspectorVisible") private var inspectorVisible = false
    @State private var feedbackModeEnabled = false
    @State private var lastOptimizationRegion: NormalizedRect?
    @State private var optimizationDraft: OptimizationNoteDraft?
    @State private var showOptimizationNotes = false
    @State private var showFeatureStatus = false
    @State private var showDuplicateReview = false
    @State private var showProjectDeletionChoices = false
    @State private var projectSwitcherPresented = false
    @State private var showProjectRenamePrompt = false
    @State private var projectRenameDraft = ""
    @State private var pendingRemovalPlan: AssetRemovalPlan?
    @State private var localFolderSelection: LocalFolderSelection?
    @State private var showsAllImportedFolderAssets = false
    @State private var selectedProjectStarScope: CurrentProjectStarScope?
    @State private var selectedFiveStarCategory: FiveStarAssetCategory?
    @State private var sidebarMode: SidebarMode = .folders
    @State private var sidebarSearch = ""
    @State private var randomSeed = UInt64.random(in: .min ... .max)
    @AppStorage("assetSidebarVisible") private var sidebarVisible = true
    @AppStorage("assetGalleryLayoutMode") private var galleryLayoutMode: AssetGalleryLayoutMode = .adaptive
    @AppStorage("galleryThumbnailWidth") private var galleryThumbnailWidth = 190.0
    @AppStorage("assetGalleryShowsName") private var galleryShowsName = true
    @AppStorage("assetGalleryShowsDescription") private var galleryShowsDescription = false
    @AppStorage("assetGalleryShowsSecondaryInfo") private var galleryShowsSecondaryInfo = true
    @AppStorage("assetGallerySecondaryInfoMode") private var gallerySecondaryInfoMode: AssetSecondaryInfoMode = .dimensionsAndSize
    @AppStorage("assetGalleryShowsExtension") private var galleryShowsExtension = true
    @AppStorage("assetGalleryShowsTags") private var galleryShowsTags = false
    @AppStorage("assetGalleryShowsTagCount") private var galleryShowsTagCount = false
    @AppStorage("assetGalleryShowsRating") private var galleryShowsRating = true
    @AppStorage("assetLocalFolderScope") private var localFolderScope: LocalFolderScope = .recursive
    @AppStorage("assetSidebarQuickAccessV1") private var sidebarQuickAccessStorage = ""

    init(dataRootURL: URL? = nil) {
        if let dataRootURL {
            _store = StateObject(wrappedValue: AssetStore(
                rootURL: dataRootURL,
                pendingSourceTrashService: QAPendingSourceTrashService(allowedRoot: dataRootURL),
                managedLibrarySSDURL: dataRootURL.appendingPathComponent(
                    AssetFrameQADataRoot.managedFiveStarDirectoryName,
                    isDirectory: true
                )
            ))
            _materialStore = StateObject(wrappedValue: GlobalMaterialStore.shared(rootURL: dataRootURL))
            _globalFiveStarStore = StateObject(wrappedValue: GlobalFiveStarStore(rootURL: dataRootURL))
            _optimizationNoteStore = StateObject(wrappedValue: OptimizationNoteStore(
                fileURL: dataRootURL.appendingPathComponent("optimization-notes.json")
            ))
        } else {
            _store = StateObject(wrappedValue: AssetStore())
            _materialStore = StateObject(wrappedValue: GlobalMaterialStore.shared())
            _globalFiveStarStore = StateObject(wrappedValue: GlobalFiveStarStore())
            _optimizationNoteStore = StateObject(wrappedValue: OptimizationNoteStore())
        }
    }

    // 用户决策看板不是独立工作区；审核状态直接在画册、表格和详情中修改。
    // 图片/表格已由顶部视图切换器承担，侧栏只保留不重复的资料库入口。
    private let workspaceViews: [SavedView] = [.materialLibrary]
    private let assetTypeViews: [SavedView] = [.people, .venues, .props, .common]
    private let smartViews: [SavedView] = [.attention, .unclassified, .master, .sourceMissing]
    private var visibleSmartViews: [SavedView] {
        smartViews.filter { $0 != .sourceMissing || store.viewCounts[$0, default: 0] > 0 }
    }
    private var sidebarQuickAccessItems: [SidebarQuickAccessItem] {
        SidebarQuickAccessCodec.decode(sidebarQuickAccessStorage).filter { $0.projectID == store.currentProject.id }
    }
    private var filteredAssets: [AssetItem] {
        let assets = scopedAssets(filter: assetFilter)
        if savedView == .random {
            return SeededAssetShuffle.ordered(assets, seed: randomSeed)
        }
        return assets
    }
    private var fileFormatCounts: [String: Int] {
        var formatNeutralFilter = assetFilter
        formatNeutralFilter.fileExtensions.removeAll()
        return scopedAssets(filter: formatNeutralFilter).reduce(into: [:]) { counts, asset in
            let format = AssetFileFormat.normalizedExtension(for: asset)
            if !format.isEmpty { counts[format, default: 0] += 1 }
        }
    }
    private var shapeCounts: [AssetAspectRatioFilterOption: Int] {
        var shapeNeutralFilter = assetFilter
        shapeNeutralFilter.aspectRatios.removeAll()
        let assets = scopedAssets(filter: shapeNeutralFilter)
        return Dictionary(uniqueKeysWithValues: AssetAspectRatioFilterOption.allCases.map { option in
            let count = assets.reduce(into: 0) { result, asset in
                guard let ratio = AssetAspectRatioFilterOption.ratio(for: asset),
                      option.matches(ratio: ratio, customRatio: assetFilter.customAspectRatio) else { return }
                result += 1
            }
            return (option, count)
        })
    }
    private func scopedAssets(filter: AssetFilter) -> [AssetItem] {
        if showsAllImportedFolderAssets {
            return store.assetsInAllLocalFolders(search: debouncedSearch, filter: filter, sort: assetSort)
        }
        if let localFolderSelection {
            return store.assets(
                inLocalFolder: localFolderSelection.sourceID,
                relativePath: localFolderSelection.relativePath,
                scope: localFolderScope,
                search: debouncedSearch,
                filter: filter,
                sort: assetSort
            )
        }
        let assets = store.assets(for: savedView, search: debouncedSearch, filter: filter, sort: assetSort)
        guard let selectedProjectStarScope, savedView != .favorites else { return assets }
        return assets.filter { selectedProjectStarScope.includes(starRating: $0.starRating) }
    }
    private var galleryChildFolders: [GalleryChildFolder] {
        guard let selection = localFolderSelection else { return [] }
        return store.galleryChildFolders(
            sourceID: selection.sourceID,
            parentPath: selection.relativePath
        )
    }
    private var showsAssetFilters: Bool {
        workspaceDestination == .assetLibrary && [.gallery, .table].contains(savedView.presentation)
    }
    private var workspaceSearchContext: WorkspaceSearchContext {
        guard workspaceDestination == .assetLibrary else {
            return workspaceDestination == .materialLibrary ? .materials : .unsupported
        }
        return switch savedView.presentation {
        case .gallery, .table, .exportLibrary: .assets
        case .fiveStarLibrary: .globalFiveStar
        case .materialLibrary: .materials
        case .attention, .trash: .unsupported
        }
    }

    private var attentionSummary: AttentionSummary {
        AttentionSummary.derive(
            assets: store.activeAssets,
            pendingImports: store.pendingImports,
            exportIssues: store.exportHealthIssues()
        )
    }
    private var queryFingerprint: String {
        "\(debouncedSearch)|\(assetFilter.type?.rawValue ?? "")|\(assetFilter.decision?.cacheKey ?? "")|\(assetFilter.reuse?.rawValue ?? "")|\(assetFilter.tag ?? "")|formats:\(assetFilter.fileExtensions.sorted().joined(separator: ","))|shapes:\(assetFilter.aspectRatios.map(\.rawValue).sorted().joined(separator: ","))|custom-ratio:\(assetFilter.customAspectRatio ?? 0)|\(assetFilter.minimumRating)|\(assetFilter.source.rawValue)|\(assetFilter.masterOnly)|\(assetSort.cacheKey)|\(localFolderSelection?.sourceID ?? "")|\(localFolderSelection?.relativePath ?? "")|scope:\(localFolderScope.rawValue)|all-folders:\(showsAllImportedFolderAssets)|star-scope:\(String(describing: selectedProjectStarScope))|random:\(savedView == .random ? randomSeed : 0)"
    }
    private var currentViewTitle: String {
        if showsAllImportedFolderAssets { return "当前项目资产 · 已链接文件夹" }
        guard let selection = localFolderSelection,
              let folder = store.localFolders.first(where: { $0.id == selection.sourceID }) else {
            if selectedProjectStarScope == .rated {
                return "当前项目 · 已评星"
            }
            if let selectedProjectStarRating = selectedProjectStarScope?.rating, selectedProjectStarRating < 5 {
                return "当前项目 · \(selectedProjectStarRating) 星"
            }
            if savedView == .allGallery {
                return "当前项目资产"
            }
            return sidebarName(for: savedView)
        }
        return selection.relativePath.isEmpty
            ? folder.name
            : "\(folder.name) / \(selection.relativePath)"
    }
    private var currentOptimizationNotes: [OptimizationNote] {
        optimizationNoteStore.notes.filter {
            $0.projectID == store.currentProject.id &&
            $0.viewName == savedView.rawValue &&
            [.pending, .planned].contains($0.effectiveStatus)
        }
    }
    private var globalFiveStarRefreshID: String {
        let projectIDs = store.projects.map(\.id).sorted().joined(separator: ",")
        return "\(store.currentProject.id)|\(store.contentRevision)|\(projectIDs)"
    }
    private var selectedAsset: AssetItem? {
        guard let id = workspaceSelection.primaryID else { return nil }
        return store.asset(withID: id)
    }

    var body: some View {
        presentedContent
    }

    private var baseContent: some View {
        VStack(spacing: 0) {
            topBar
            if let selectedAsset {
                AssetSelectionInfoBar(asset: selectedAsset)
            }
            if showsAssetFilters {
                AssetFilterBar(
                    filter: $assetFilter,
                    sort: $assetSort,
                    tags: store.availableTags,
                    formatCounts: fileFormatCounts,
                    shapeCounts: shapeCounts,
                    resultCount: filteredAssets.count
                )
            }
            GeometryReader { workspace in
                HSplitView {
                    if sidebarVisible {
                        viewsSidebar
                            .frame(minWidth: 180, idealWidth: 222, maxWidth: 270)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    ProjectLoadContentContainer(
                        isLoading: store.isLoadingProject,
                        showsProgress: store.showsProjectLoadOverlay,
                        progress: store.projectLoadProgress,
                        errorMessage: store.projectLoadErrorMessage,
                        retry: store.retryProjectLoad,
                        revealProjectData: store.revealCurrentProjectData
                    ) {
                        centerView
                    }
                        .frame(minWidth: 460)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(GraphiteTheme.canvas)
                    if inspectorVisible && workspaceDestination == .assetLibrary && savedView.presentation != .attention {
                        inspector
                            .frame(minWidth: 280, idealWidth: 350, maxWidth: 440)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(width: workspace.size.width, height: workspace.size.height, alignment: .topLeading)
                .contextMenu {
                    Button("记录优化建议备注…", systemImage: "square.and.pencil", action: beginOptimizationNote)
                    Divider()
                    Button("查看优化建议", systemImage: "note.text") { showOptimizationNotes = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)
        }
        .frame(minWidth: 900, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.canvas)
        .tint(GraphiteTheme.accent)
    }

    private var overlayContent: some View {
        baseContent
        .overlay { if isDropping { DropOverlay().allowsHitTesting(false) } }
        .overlay(alignment: .bottomTrailing) {
            if materialStore.resumableImport != nil && !materialStore.isImporting {
                Button("继续未完成的素材导入", action: materialStore.resumeImport)
                    .buttonStyle(.borderedProminent).padding(18)
            } else if receivingDrop || materialStore.importProgressVisible {
                MaterialImportProgressCard(store: materialStore, receivingDrop: receivingDrop)
                    .padding(18)
            }
        }
        .overlay {
            OptimizationFeedbackHighlights(
                notes: currentOptimizationNotes,
                draft: optimizationDraft,
                isEnabled: feedbackModeEnabled
            )
        }
        .overlay {
            OptimizationFeedbackCapture(isEnabled: optimizationDraft == nil) { region in
                lastOptimizationRegion = region
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            if workspaceDestination == .assetLibrary {
                VStack(alignment: .trailing, spacing: 10) {
                    if !store.duplicateImportCandidates.isEmpty {
                        DuplicateImportQueueCard(count: store.duplicateImportCandidates.count) {
                            showDuplicateReview = true
                        }
                    }
                    if store.resumableImport != nil && !store.isImporting {
                        Button("继续未完成的图片导入", action: store.resumeImageImport)
                            .buttonStyle(.borderedProminent)
                    }
                    ImportProgressOverlay(
                        controller: store.importProgressController,
                        isImporting: store.isImporting,
                        reduceMotion: reduceMotion,
                        onDismiss: store.dismissImportProgress,
                        onCancel: store.cancelImageImport
                    )
                }
                // Keep the card clear of macOS overlay scroll bars so indexing
                // never gets in the way of gallery scrolling or resizing.
                .padding(.bottom, 30)
                .padding(.trailing, 18)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let progress = store.exportProgress {
                ExportProgressCard(progress: progress, canDismiss: progress.phase != .exporting) {
                    store.dismissExportProgress()
                }
                .padding(.top, 74)
                .padding(.trailing, 18)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                HStack(spacing: 12) {
                    Label(toast, systemImage: store.undoTrashAssetID == nil ? "checkmark.circle.fill" : "trash.fill")
                    if store.undoTrashAssetID != nil {
                        Divider().frame(height: 18)
                        Button("撤销") { store.undoLastTrash() }.buttonStyle(.borderless).fontWeight(.semibold)
                    }
                }
                .font(.callout.weight(.medium)).padding(.horizontal, 15).padding(.vertical, 10)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 9))
                .shadow(radius: 16, y: 5).padding(.bottom, 24)
            }
        }
    }

    private var fileCommandContent: some View {
        overlayContent
        .environment(\.fileImportDropHandler, { urls in importWorkspaceURLs(urls) })
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropping) { providers in isDropping = false; importDropped(providers); return true }
        .onReceive(NotificationCenter.default.publisher(for: .importAssetImages)) { _ in chooseWorkspaceImport() }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFolder)) { _ in store.chooseProjectFolder() }
        .onReceive(NotificationCenter.default.publisher(for: .linkMaterialFolder)) { _ in store.chooseLocalFolder() }
        .onReceive(NotificationCenter.default.publisher(for: .scanCurrentProject)) { _ in store.scanCurrentFolderForNewImages() }
        .onReceive(NotificationCenter.default.publisher(for: .exportAssetCSV)) { _ in store.exportCSV() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAssetSidebar)) { _ in sidebarVisible.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAssetInspector)) { _ in toggleInspectorFromCommand() }
    }

    private var workspaceCommandContent: some View {
        fileCommandContent
        .onReceive(NotificationCenter.default.publisher(for: .showAssetLibrary)) { _ in selectWorkspace(.assetLibrary) }
        .onReceive(NotificationCenter.default.publisher(for: .showMaterialLibrary)) { _ in selectWorkspace(.materialLibrary) }
        .onReceive(NotificationCenter.default.publisher(for: .showExportLibrary)) { _ in selectWorkspace(.exportLibrary) }
        .onReceive(NotificationCenter.default.publisher(for: .showAssetTrash)) { _ in selectWorkspace(.trash) }
        .onReceive(NotificationCenter.default.publisher(for: .previewSelectedAsset)) { _ in previewCurrentSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .rateSelectedAssets)) { notification in
            guard let rating = notification.userInfo?["rating"] as? Int else { return }
            rateCurrentSelection(rating)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFeatureStatus)) { _ in showFeatureStatus = true }
    }

    private var featureEventContent: some View {
        workspaceCommandContent
        .onReceive(NotificationCenter.default.publisher(for: .addAssetsToExportLibrary)) { notification in
            if let ids = notification.userInfo?["ids"] as? [String] { store.addToExportLibrary(Set(ids)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importedAssetsAvailable)) { _ in
            guard localFolderSelection == nil else { return }
            selectCurrentProjectAssets()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordOptimizationFeedback)) { _ in
            beginOptimizationNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOptimizationNotes)) { _ in
            showOptimizationNotes = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusWorkspaceSearch)) { _ in
            if workspaceSearchContext == .assets { assetSearchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewAssetImage)) { notification in
            guard let id = notification.userInfo?["id"] as? String,
                  filteredAssets.contains(where: { $0.id == id }) else { return }
            workspaceSelection.preview(id)
            inspectorVisible = true
        }
    }

    private var eventContent: some View {
        featureEventContent
        .onAppear {
            if workspaceDestination != .assetLibrary {
                savedView = workspaceDestination.savedView
            }
            workspaceSelection.clearForContextChange()
        }
        .onChange(of: savedView) { _, _ in
            workspaceSelection.clearForContextChange()
        }
        .task(id: search) {
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            debouncedSearch = search
        }
        .onChange(of: store.currentProject.id) {
            showDuplicateReview = false
            localFolderSelection = nil
            showsAllImportedFolderAssets = false
            selectedProjectStarScope = nil
            selectedFiveStarCategory = nil
            workspaceSelection.clearForContextChange()
        }
        .onChange(of: store.localFolders.map(\.id)) { oldIDs, newIDs in
            guard let addedID = newIDs.first(where: { !oldIDs.contains($0) }) else { return }
            sidebarMode = .folders
            sidebarVisible = true
            selectLocalFolder(LocalFolderSelection(sourceID: addedID, relativePath: ""))
        }
        .task(id: globalFiveStarRefreshID) {
            await globalFiveStarStore.refresh(
                projects: store.projects,
                currentProjectID: store.currentProject.id,
                currentAssets: store.activeAssets
            )
        }
    }

    private var presentedContent: some View {
        eventContent
        .alert("暂时无法导出", isPresented: Binding(get: { store.exportValidationMessage != nil }, set: { if !$0 { store.exportValidationMessage = nil } })) {
            Button("知道了") { store.exportValidationMessage = nil }
        } message: { Text(store.exportValidationMessage ?? "") }
        .alert("操作未完成", isPresented: Binding(get: { store.assetActionMessage != nil }, set: { if !$0 { store.assetActionMessage = nil } })) {
            Button("知道了") { store.assetActionMessage = nil }
        } message: { Text(store.assetActionMessage ?? "") }
        .confirmationDialog(
            "处理所选 \(pendingRemovalPlan?.totalCount ?? 0) 项？",
            isPresented: Binding(
                get: { pendingRemovalPlan != nil },
                set: { if !$0 { pendingRemovalPlan = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let plan = pendingRemovalPlan {
                ForEach(plan.actions) { action in
                    Button(action.title, role: .destructive) { executeRemoval(action) }
                }
            }
            Button("取消", role: .cancel) { pendingRemovalPlan = nil }
        } message: {
            Text(pendingRemovalPlan?.actions.map(\.confirmationMessage).joined(separator: "\n") ?? "")
        }
        .sheet(isPresented: $showDuplicateReview) {
            if !store.duplicateImportCandidates.isEmpty {
                DuplicateImportReviewSheet(
                    candidates: store.duplicateImportCandidates,
                    onConfirm: { candidateID, decision, applyToAll in
                        store.resolveDuplicateImport(candidateID, decision: decision, applyToAll: applyToAll)
                        if store.duplicateImportCandidates.isEmpty { showDuplicateReview = false }
                    },
                    onRevealInFinder: store.revealDuplicateImportsInFinder,
                    onDismiss: { showDuplicateReview = false }
                )
            }
        }
        .alert("项目删除未完成", isPresented: Binding(get: { store.projectDeletionMessage != nil }, set: { if !$0 { store.projectDeletionMessage = nil } })) {
            Button("知道了") { store.projectDeletionMessage = nil }
        } message: { Text(store.projectDeletionMessage ?? "") }
        .confirmationDialog("删除“\(store.currentProject.name)”？", isPresented: $showProjectDeletionChoices, titleVisibility: .visible) {
            Button("仅删除项目记录，保留记忆库") { store.removeCurrentProjectKeepingMemory() }
            Button("删除项目记录和整个记忆库", role: .destructive) { store.removeCurrentProjectAndMemory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保留记忆库：保留该项目的素材库、筛图队列和数据库，之后可重新打开。\n删除整个记忆库：上述内容会移入系统废纸篓；项目文件夹及其中其他文件不会删除。")
        }
        .alert("重命名项目显示名称", isPresented: $showProjectRenamePrompt) {
            TextField("项目名称", text: $projectRenameDraft)
            Button("取消", role: .cancel) {}
            Button("重命名", action: renameCurrentProject)
                .disabled(projectRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("只修改 AssetFrame 中显示的项目名称，不会重命名 Finder 文件夹，也不会改变原图路径。")
        }
        .sheet(item: $optimizationDraft) { draft in
            OptimizationNoteEditor(
                draft: draft,
                onSave: { text in
                    optimizationNoteStore.add(draft: draft, text: text)
                    optimizationDraft = nil
                },
                onCancel: { optimizationDraft = nil }
            )
        }
        .sheet(isPresented: $showOptimizationNotes) {
            OptimizationNotesView(
                notes: optimizationNoteStore.notes,
                onStatusChange: { note, status in optimizationNoteStore.updateStatus(note, status: status) },
                onDelete: optimizationNoteStore.remove
            )
        }
        .sheet(isPresented: $showFeatureStatus) {
            FeatureStatusView(onClose: { showFeatureStatus = false })
        }
    }

    private func beginOptimizationNote() {
        let region = lastOptimizationRegion ?? NormalizedRect(x: 0.35, y: 0.35, width: 0.30, height: 0.24)
        optimizationDraft = OptimizationNoteDraft(
            projectID: store.currentProject.id,
            projectName: store.currentProject.name,
            viewName: savedView.rawValue,
            region: region
        )
    }

    private var topBar: some View {
        ResponsiveCommandBar {
            expandedTopBar
        } compact: {
            compactTopBar
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(GraphiteTheme.toolbar)
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
    }

    private var expandedTopBar: some View {
        HStack(spacing: 10) {
            Button(sidebarVisible ? "隐藏侧栏" : "显示侧栏", systemImage: "sidebar.left") {
                sidebarVisible.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("s", modifiers: [.command, .option])
            .help(sidebarVisible ? "隐藏侧栏（⌥⌘S）" : "显示侧栏（⌥⌘S）")
            Button {
                projectSwitcherPresented.toggle()
            } label: {
                ProjectSwitcherLabel(projectName: store.displayedProjectName)
            }
            .buttonStyle(.plain)
            .help("切换项目，当前：\(store.displayedProjectName)")
            .popover(isPresented: $projectSwitcherPresented, arrowEdge: .bottom) {
                projectSwitcherPopover
            }
            if workspaceDestination == .assetLibrary {
                Picker("主视图", selection: assetPresentationBinding) {
                    Text("图片").tag(SavedView.allGallery)
                    Text("表格").tag(SavedView.allTable)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 132)
            }
            Spacer()
            if workspaceSearchContext == .assets {
                TextField("搜索资产…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .focused($assetSearchFocused)
                    .accessibilityIdentifier("assetframe.workspace-search.assets")
            }
            Button(inspectorVisible ? "隐藏详情" : "显示详情", systemImage: "sidebar.right") {
                inspectorVisible.toggle()
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(inspectorVisible ? "收起详情" : "显示详情")
                .disabled(workspaceDestination != .assetLibrary || savedView.presentation == .attention)
            Button {
                chooseWorkspaceImport()
            } label: {
                Label(store.isProjectScanning ? "扫描中…" : (store.isImporting ? "处理中…" : "导入"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isImporting)
            Menu {
                Button {
                    feedbackModeEnabled.toggle()
                } label: {
                    Label(feedbackModeEnabled ? "隐藏区域标记" : "显示区域标记", systemImage: feedbackModeEnabled ? "eye.slash" : "scope")
                }
                Button { showOptimizationNotes = true } label: {
                    Label("优化建议（\(optimizationNoteStore.notes.count)）", systemImage: "note.text")
                }
                Divider()
                Button("扫描当前项目", systemImage: "arrow.clockwise", action: store.scanCurrentFolderForNewImages)
                    .disabled(store.isImporting)
                Button { store.exportCSV() } label: { Label("导出 CSV 备份", systemImage: "tablecells") }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
        }
    }

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            Button(sidebarVisible ? "隐藏侧栏" : "显示侧栏", systemImage: "sidebar.left") {
                sidebarVisible.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            Button {
                projectSwitcherPresented.toggle()
            } label: {
                ProjectSwitcherLabel(projectName: store.displayedProjectName)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $projectSwitcherPresented, arrowEdge: .bottom) { projectSwitcherPopover }
            if workspaceDestination == .assetLibrary {
                Picker("主视图", selection: assetPresentationBinding) {
                    Text("图片").tag(SavedView.allGallery)
                    Text("表格").tag(SavedView.allTable)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 104)
            }
            Spacer(minLength: 4)
            if workspaceSearchContext == .assets {
                TextField("搜索资产…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .focused($assetSearchFocused)
                    .accessibilityIdentifier("assetframe.workspace-search.assets.compact")
            }
            Button(inspectorVisible ? "隐藏详情" : "显示详情", systemImage: "sidebar.right") {
                inspectorVisible.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(workspaceDestination != .assetLibrary || savedView.presentation == .attention)
            Button(store.isImporting ? "处理中…" : "导入", systemImage: "plus", action: chooseWorkspaceImport)
                .buttonStyle(.borderedProminent)
                .disabled(store.isImporting)
            Menu("更多", systemImage: "ellipsis.circle") {
                Button("扫描当前项目", systemImage: "arrow.clockwise", action: store.scanCurrentFolderForNewImages)
                    .disabled(store.isImporting)
                Divider()
                Button(feedbackModeEnabled ? "隐藏区域标记" : "显示区域标记", systemImage: feedbackModeEnabled ? "eye.slash" : "scope") { feedbackModeEnabled.toggle() }
                Button("优化建议（\(optimizationNoteStore.notes.count)）", systemImage: "note.text") { showOptimizationNotes = true }
                Button("导出 CSV 备份", systemImage: "tablecells", action: store.exportCSV)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var assetPresentationBinding: Binding<SavedView> {
        Binding(
            get: { savedView == .allTable ? .allTable : .allGallery },
            set: { presentation in
                workspaceDestination = .assetLibrary
                if presentation == .allTable || presentation == .allGallery {
                    selectSavedView(presentation)
                }
            }
        )
    }

    private var projectSwitcherPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("切换项目")
                    .font(.headline)
                Spacer()
                Text("\(store.projects.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.projects) { project in
                        Button {
                            store.switchProject(project.id)
                            projectSwitcherPresented = false
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: project.id == store.currentProject.id ? "folder.fill" : "folder")
                                    .foregroundStyle(project.id == store.currentProject.id ? .blue : .secondary)
                                    .frame(width: 20)
                                Text(project.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if project.id == store.currentProject.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            project.id == store.currentProject.id ? Color.accentColor.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 260)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                projectSwitcherAction("添加／打开项目…", systemImage: "folder.badge.plus") {
                    projectSwitcherPresented = false
                    store.chooseProjectFolder()
                }
                projectSwitcherAction("重命名项目显示名称…", systemImage: "pencil") {
                    projectSwitcherPresented = false
                    beginProjectRename()
                }
                projectSwitcherAction("检查已建档原图", systemImage: "arrow.clockwise") {
                    projectSwitcherPresented = false
                    store.scanCurrentProject()
                }
                projectSwitcherAction("扫描当前文件夹", systemImage: "folder.badge.plus") {
                    projectSwitcherPresented = false
                    store.scanCurrentFolderForNewImages()
                }
                projectSwitcherAction("在 Finder 中打开", systemImage: "folder") {
                    projectSwitcherPresented = false
                    store.revealCurrentProject()
                }
                projectSwitcherAction("重新定位项目…", systemImage: "arrow.triangle.2.circlepath") {
                    projectSwitcherPresented = false
                    store.relocateCurrentProject()
                }
                projectSwitcherAction("删除当前项目…", systemImage: "trash", destructive: true) {
                    projectSwitcherPresented = false
                    showProjectDeletionChoices = true
                }
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    private func projectSwitcherAction(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func beginProjectRename() {
        projectRenameDraft = store.currentProject.name
        showProjectRenamePrompt = true
    }

    private func renameCurrentProject() {
        if store.renameCurrentProject(to: projectRenameDraft) {
            projectRenameDraft = ""
        }
    }
    private var viewsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("工作区", systemImage: "sidebar.left")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }.padding(.horizontal, 12).frame(height: 36)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    workspaceButton(.assetLibrary, count: store.activeAssets.count + store.pendingImports.count)

                    if workspaceDestination == .assetLibrary {
                        Picker("资产库浏览方式", selection: $sidebarMode) {
                            ForEach(SidebarMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                        if sidebarMode == .folders {
                            viewButton(.attention)
                                .padding(.horizontal, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                PinnedFolderQuickAccessSection(
                                    items: sidebarQuickAccessItems,
                                    folders: store.localFolders,
                                    selectedFolder: localFolderSelection,
                                    searchQuery: sidebarSearch,
                                    onSelect: selectQuickAccessItem,
                                    onRemove: toggleQuickAccessItem,
                                    onMove: moveQuickAccessItem,
                                    onReorder: reorderQuickAccessItem
                                )
                                LocalFolderSidebarSection(
                                    store: store,
                                    selection: $localFolderSelection,
                                    currentProjectStarCounts: currentProjectStarCounts,
                                    currentProjectFiveStarCategoryCounts: currentProjectFiveStarCategoryCounts,
                                    globalFiveStarCount: globalFiveStarStore.count(scope: .allProjects, projectID: store.currentProject.id),
                                    allImportedFolderAssetCount: store.allLocalFolderAssetCount,
                                    isAllImportedFoldersSelected: showsAllImportedFolderAssets,
                                    isCurrentProjectAssetsSelected: localFolderSelection == nil && !showsAllImportedFolderAssets && selectedProjectStarScope == nil && savedView == .allGallery,
                                    selectedCurrentProjectRating: localFolderSelection == nil ? selectedProjectStarScope?.rating : nil,
                                    selectedCurrentProjectFiveStarCategory: localFolderSelection == nil ? selectedFiveStarCategory : nil,
                                    isGlobalFiveStarSelected: localFolderSelection == nil && savedView == .globalFavorites,
                                    onSelectCurrentProjectAssets: selectCurrentProjectAssets,
                                    onSelectCurrentProjectRating: selectCurrentProjectRating,
                                    onSelectCurrentProjectFiveStarCategory: selectCurrentProjectFiveStarCategory,
                                    onSelectGlobalFiveStar: { selectSavedView(.globalFavorites) },
                                    onSelectAllImportedFolders: selectAllImportedFolders,
                                    onSelect: selectLocalFolder,
                                    folderScope: $localFolderScope,
                                    searchQuery: sidebarSearch,
                                    quickAccessItems: sidebarQuickAccessItems,
                                    onToggleQuickAccess: toggleQuickAccessItem,
                                    onFolderRenamed: updateQuickAccessAfterRename
                                )
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                sidebarTitle("待处理")
                                ForEach(sidebarViewsMatchingSearch([.attention])) { viewButton($0) }
                                sidebarTitle("类型").padding(.top, 6)
                                ForEach(sidebarViewsMatchingSearch(assetTypeViews)) { viewButton($0) }
                                sidebarTitle("智能整理").padding(.top, 6)
                                ForEach(sidebarViewsMatchingSearch(visibleSmartViews.filter { $0 != .attention })) { viewButton($0) }
                            }
                        }
                    }

                    Divider().padding(.horizontal, 8).padding(.vertical, 4)
                    workspaceButton(.materialLibrary, count: materialStore.materials.count)
                    workspaceButton(.exportLibrary, count: store.exportAssets.count)
                    workspaceButton(.trash, count: store.trashedAssets.count)
                }
                .padding(5)
                .transaction { $0.animation = nil }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("筛选侧栏…", text: $sidebarSearch)
                    .textFieldStyle(.plain)
                if !sidebarSearch.isEmpty {
                    Button("清除侧栏筛选", systemImage: "xmark.circle.fill", action: { sidebarSearch = "" })
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            Divider()
            Button(action: store.revealCurrentProject) {
                HStack(spacing: 7) {
                    Image(systemName: "internaldrive")
                    Text(store.currentProjectRootURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
            }
            .buttonStyle(.plain)
            .help(store.currentProjectRootURL.path)
            .contextMenu {
                Button("在 Finder 中打开", systemImage: "folder", action: store.revealCurrentProject)
                Button("复制本地路径", systemImage: "doc.on.doc", action: store.copyCurrentProjectPath)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GraphiteTheme.sidebar)
    }

    private func workspaceButton(_ destination: WorkspaceDestination, count: Int) -> some View {
        let isSelected = workspaceDestination == destination
        return Button {
            selectWorkspace(destination)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: destination.systemImage)
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(destination.displayName)
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "当前工作区" : "")
    }

    private func sidebarViewsMatchingSearch(_ views: [SavedView]) -> [SavedView] {
        views.filter { SidebarSearchMatcher.matches(sidebarSearch, candidates: [sidebarName(for: $0), $0.rawValue]) }
    }

    private func selectQuickAccessItem(_ item: SidebarQuickAccessItem) {
        guard store.localFolders.contains(where: { $0.id == item.sourceID }) else { return }
        selectLocalFolder(LocalFolderSelection(sourceID: item.sourceID, relativePath: item.relativePath))
    }

    private func toggleQuickAccessItem(_ item: SidebarQuickAccessItem) {
        let updated = SidebarQuickAccessCodec.toggling(item, in: sidebarQuickAccessItems)
        replaceCurrentProjectQuickAccess(with: updated)
    }

    private func moveQuickAccessItem(_ itemID: String, _ offset: Int) {
        let updated = SidebarQuickAccessCodec.moving(itemID, by: offset, in: sidebarQuickAccessItems)
        replaceCurrentProjectQuickAccess(with: updated)
    }

    private func reorderQuickAccessItem(_ itemID: String, _ destinationID: String) {
        let updated = SidebarQuickAccessCodec.moving(itemID, before: destinationID, in: sidebarQuickAccessItems)
        replaceCurrentProjectQuickAccess(with: updated)
    }

    private func replaceCurrentProjectQuickAccess(with currentItems: [SidebarQuickAccessItem]) {
        let otherProjects = SidebarQuickAccessCodec.decode(sidebarQuickAccessStorage).filter {
            $0.projectID != store.currentProject.id
        }
        sidebarQuickAccessStorage = SidebarQuickAccessCodec.encode(otherProjects + currentItems)
    }

    private func updateQuickAccessAfterRename(_ sourceID: String, _ oldPath: String, _ newPath: String) {
        let updated = SidebarQuickAccessCodec.replacingRenamedPath(
            projectID: store.currentProject.id,
            sourceID: sourceID,
            oldPath: oldPath,
            newPath: newPath,
            in: SidebarQuickAccessCodec.decode(sidebarQuickAccessStorage)
        )
        sidebarQuickAccessStorage = SidebarQuickAccessCodec.encode(updated)
    }
    private func sidebarTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
    private func viewButton(_ view: SavedView) -> some View {
        let count = view == .quickReview ? store.pendingImports.count : store.viewCounts[view, default: 0]
        return Button {
            selectSavedView(view)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon(for: view))
                    .frame(width: 16)
                    .foregroundStyle(savedView == view && localFolderSelection == nil ? Color.accentColor : Color.secondary)
                Text(sidebarName(for: view))
                Spacer()
                Text("\(count)").foregroundStyle(.tertiary)
            }
                .font(.callout.weight(savedView == view && localFolderSelection == nil ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    savedView == view && localFolderSelection == nil ? Color.accentColor.opacity(0.13) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }.buttonStyle(.plain)
    }
    private func icon(for view: SavedView) -> String {
        switch view {
        case .allGallery: "rectangle.grid.2x2"
        case .allTable: "tablecells"
        case .attention: "checklist"
        case .materialLibrary: "square.stack.3d.up"
        case .quickReview: "rectangle.on.rectangle.angled"
        case .exportLibrary: "shippingbox"
        case .people: "person.crop.rectangle"
        case .venues: "building.2"
        case .props: "archivebox"
        case .common: "square.stack.3d.up"
        case .unclassified: "questionmark.folder"
        case .untagged: "tag.slash"
        case .pending: "clock"
        case .master: "sparkles.rectangle.stack"
        case .favorites: "star.fill"
        case .globalFavorites: "square.stack.3d.up.fill"
        case .recent: "clock.arrow.circlepath"
        case .recentlyUsed: "clock.arrow.circlepath"
        case .random: "shuffle"
        case .today: "calendar"
        case .sourceMissing: "exclamationmark.triangle"
        case .confirmed: "checkmark.circle"
        case .rejected: "xmark.circle"
        case .episode1: "film.stack"
        case .trash: "trash"
        }
    }

    private func sidebarName(for view: SavedView) -> String {
        switch view {
        case .unclassified: "待整理"
        case .sourceMissing: "文件异常"
        default: view.rawValue
        }
    }

    @ViewBuilder private var centerView: some View {
        switch savedView.presentation {
        case .table:
            AssetTableView(
                store: store,
                assets: filteredAssets,
                selectionModel: workspaceSelection,
                onRequestRemoval: requestRemoval
            )
        case .gallery:
            AssetGalleryView(
                title: currentViewTitle,
                store: store,
                assets: filteredAssets,
                contentVersion: GalleryContentVersion(revision: store.contentRevision, viewID: savedView.rawValue, query: queryFingerprint),
                selectionModel: workspaceSelection,
                layoutMode: $galleryLayoutMode,
                sort: $assetSort,
                thumbnailWidth: $galleryThumbnailWidth,
                showsName: $galleryShowsName,
                showsDescription: $galleryShowsDescription,
                showsSecondaryInfo: $galleryShowsSecondaryInfo,
                secondaryInfoMode: $gallerySecondaryInfoMode,
                showsExtension: $galleryShowsExtension,
                showsTags: $galleryShowsTags,
                showsTagCount: $galleryShowsTagCount,
                showsRating: $galleryShowsRating,
                folderScope: $localFolderScope,
                showsSidebar: $sidebarVisible,
                showsInspector: $inspectorVisible,
                folderScopeEnabled: localFolderSelection != nil,
                childFolders: galleryChildFolders,
                selectChildFolder: selectLocalFolder,
                emptyStateKind: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .noSearchResults
                    : (assetFilter.isActive ? .noFilterResults : .emptyLibrary),
                clearQuery: clearAssetQuery,
                onRequestRemoval: requestRemoval
            )
        case .attention:
            AttentionCenterView(
                summary: attentionSummary,
                onOpenUnclassified: { selectSavedView(.unclassified) },
                onOpenMissingSources: { selectSavedView(.sourceMissing) },
                onOpenExportLibrary: { selectWorkspace(.exportLibrary) }
            )
        case .trash: TrashView(store: store, assets: filteredAssets)
        case .exportLibrary:
            ExportLibraryView(store: store, assets: filteredAssets, onResolveIssue: resolveExportIssue)
        case .materialLibrary:
            MaterialLibraryView(store: materialStore, project: store.currentProject) { material in
                materialStore.setLink(materialID: material.id, projectID: store.currentProject.id, use: .candidate)
                store.addGlobalMaterialCandidate(material)
            }
        case .fiveStarLibrary:
            GlobalFiveStarView(
                store: globalFiveStarStore,
                scope: savedView == .globalFavorites ? .allProjects : .currentProject,
                project: store.currentProject,
                category: savedView == .favorites ? selectedFiveStarCategory : nil,
                layoutMode: $galleryLayoutMode,
                sort: $assetSort,
                thumbnailWidth: $galleryThumbnailWidth,
                showsName: $galleryShowsName,
                showsDescription: $galleryShowsDescription,
                showsSecondaryInfo: $galleryShowsSecondaryInfo,
                secondaryInfoMode: $gallerySecondaryInfoMode,
                showsExtension: $galleryShowsExtension,
                showsTags: $galleryShowsTags,
                showsTagCount: $galleryShowsTagCount,
                showsRating: $galleryShowsRating,
                folderScope: $localFolderScope,
                showsSidebar: $sidebarVisible,
                showsInspector: $inspectorVisible,
                selectionModel: workspaceSelection
            )
        }
    }

    private func selectLocalFolder(_ folderSelection: LocalFolderSelection) {
        workspaceDestination = .assetLibrary
        showsAllImportedFolderAssets = false
        localFolderSelection = folderSelection
        selectedProjectStarScope = nil
        selectedFiveStarCategory = nil
        savedView = .allGallery
        workspaceSelection.clearForContextChange()
    }

    private func selectSavedView(_ view: SavedView) {
        switch view {
        case .quickReview:
            workspaceDestination = .assetLibrary
        case .materialLibrary:
            workspaceDestination = .materialLibrary
        case .exportLibrary:
            workspaceDestination = .exportLibrary
        case .trash:
            workspaceDestination = .trash
        default:
            workspaceDestination = .assetLibrary
        }
        showsAllImportedFolderAssets = false
        localFolderSelection = nil
        selectedProjectStarScope = nil
        selectedFiveStarCategory = nil
        if view == .random {
            randomSeed = UInt64.random(in: .min ... .max)
        } else if view == .recentlyUsed {
            assetSort = .usedNewest
        }
        savedView = view == .quickReview ? .allGallery : view
        workspaceSelection.clearForContextChange()
    }

    private func selectWorkspace(_ destination: WorkspaceDestination) {
        workspaceDestination = destination
        if destination != .assetLibrary {
            selectSavedView(destination.savedView)
        } else if [.quickReview, .materialLibrary, .exportLibrary, .trash].contains(savedView) {
            selectCurrentProjectAssets()
        }
        inspectorVisible = destination == .assetLibrary ? inspectorVisible : false
        workspaceSelection.clearForContextChange()
    }

    private func previewCurrentSelection() {
        guard workspaceDestination == .assetLibrary,
              let id = workspaceSelection.primaryID,
              filteredAssets.contains(where: { $0.id == id }) else { return }
        if workspaceSelection.previewID != nil { workspaceSelection.closePreview() }
        else { workspaceSelection.preview(id); inspectorVisible = true }
    }

    private func toggleInspectorFromCommand() {
        guard workspaceDestination == .assetLibrary else { return }
        guard savedView.presentation != .attention else { return }
        inspectorVisible.toggle()
    }

    private func rateCurrentSelection(_ rating: Int) {
        guard workspaceDestination != .materialLibrary else { return }
        guard workspaceDestination == .assetLibrary else {
            store.showToast("评分只适用于资产库中的素材")
            return
        }
        let targets = Set(workspaceSelection.selectedIDs.map(AssetActionTarget.gallery))
        guard !targets.isEmpty else {
            store.showToast("请先选择要评分的素材")
            return
        }
        let resolved = store.performSetRating(rating, on: targets)
        if !resolved.isEmpty { workspaceSelection.select(Set(resolved.map(\.galleryID))) }
    }

    private var currentProjectStarCounts: [Int: Int] {
        var counts = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, 0) })
        for asset in store.activeAssets where (1...4).contains(asset.starRating) {
            counts[asset.starRating, default: 0] += 1
        }
        counts[5] = globalFiveStarStore.count(scope: .currentProject, projectID: store.currentProject.id)
        return counts
    }

    private var currentProjectFiveStarCategoryCounts: [FiveStarAssetCategory: Int] {
        Dictionary(uniqueKeysWithValues: FiveStarAssetCategory.allCases.map { category in
            (category, globalFiveStarStore.count(scope: .currentProject, projectID: store.currentProject.id, category: category))
        })
    }

    private func selectCurrentProjectRating(_ rating: Int) {
        workspaceDestination = .assetLibrary
        showsAllImportedFolderAssets = false
        localFolderSelection = nil
        selectedProjectStarScope = .rating(rating)
        selectedFiveStarCategory = nil
        assetFilter.minimumRating = 0
        savedView = rating == 5 ? .favorites : .allGallery
        workspaceSelection.clearForContextChange()
    }

    private func selectCurrentProjectFiveStarCategory(_ category: FiveStarAssetCategory) {
        workspaceDestination = .assetLibrary
        showsAllImportedFolderAssets = false
        localFolderSelection = nil
        selectedProjectStarScope = .rating(5)
        selectedFiveStarCategory = category
        savedView = .favorites
        workspaceSelection.clearForContextChange()
    }

    private func selectCurrentProjectAssets() {
        workspaceDestination = .assetLibrary
        showsAllImportedFolderAssets = false
        localFolderSelection = nil
        selectedProjectStarScope = nil
        selectedFiveStarCategory = nil
        assetFilter.minimumRating = 0
        savedView = .allGallery
        workspaceSelection.clearForContextChange()
    }

    private func selectAllImportedFolders() {
        workspaceDestination = .assetLibrary
        showsAllImportedFolderAssets = true
        localFolderSelection = nil
        selectedProjectStarScope = nil
        selectedFiveStarCategory = nil
        savedView = .allGallery
        workspaceSelection.clearForContextChange()
    }

    private func clearAssetQuery() {
        search = ""
        debouncedSearch = ""
        assetFilter.reset()
    }

    private func resolveExportIssue(_ issue: ExportHealthIssue) {
        selectCurrentProjectAssets()
        clearAssetQuery()
        search = issue.assetID
        debouncedSearch = issue.assetID
        if issue.kind == .missingSource { assetFilter.source = .missing }
        if issue.kind == .unclassified { assetFilter.type = .unclassified }
        workspaceSelection.select([issue.assetID])
        inspectorVisible = true
    }

    private var inspectorScopeSummary: InspectorScopeSummary {
        InspectorScopeSummary(
            title: currentViewTitle,
            itemCount: filteredAssets.count,
            totalFileSize: filteredAssets.reduce(Int64(0)) { $0 + max(0, $1.sourceFileSize ?? 0) },
            missingSourceCount: filteredAssets.lazy.filter(\.sourceMissing).count,
            queryIsActive: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assetFilter.isActive
        )
    }

    private var globalFiveStarInspectorRecords: [GlobalFiveStarRecord] {
        guard savedView.presentation == .fiveStarLibrary else { return [] }
        return globalFiveStarStore.records(
            scope: savedView == .globalFavorites ? .allProjects : .currentProject,
            projectID: store.currentProject.id,
            search: "",
            type: nil,
            category: savedView == .favorites ? selectedFiveStarCategory : nil
        )
    }

    private var globalFiveStarInspectorAssets: [AssetItem] {
        globalFiveStarInspectorRecords.map(\.galleryAsset)
    }

    private var globalFiveStarScopeSummary: InspectorScopeSummary {
        InspectorScopeSummary(
            title: currentViewTitle,
            itemCount: globalFiveStarInspectorAssets.count,
            totalFileSize: globalFiveStarInspectorAssets.reduce(Int64(0)) { $0 + max(0, $1.sourceFileSize ?? 0) },
            missingSourceCount: globalFiveStarInspectorAssets.lazy.filter(\.sourceMissing).count,
            queryIsActive: false
        )
    }

    private var inspectorSelectionRecords: [InspectorSelectionRecord] {
        filteredAssets.map { asset in
            InspectorSelectionRecord(
                id: asset.id,
                kind: pendingGalleryImportID(from: asset.id) == nil ? .formal : .pending,
                fileSize: asset.sourceFileSize,
                sourceMissing: asset.sourceMissing
            )
        }
    }

    private var effectiveInspectorSelectedIDs: Set<String> {
        workspaceSelection.selectedIDs
    }

    @ViewBuilder private var inspector: some View {
        if savedView.presentation == .fiveStarLibrary {
            globalFiveStarInspector
        } else {
            standardAssetInspector
        }
    }

    @ViewBuilder private var globalFiveStarInspector: some View {
        let records = globalFiveStarInspectorRecords.map { record in
            InspectorSelectionRecord(
                id: record.id,
                kind: .globalFiveStar,
                fileSize: record.galleryAsset.sourceFileSize,
                sourceMissing: record.galleryAsset.sourceMissing
            )
        }
        switch ContextualInspectorResolver.resolve(
            selectedIDs: workspaceSelection.selectedIDs,
            records: records,
            scope: globalFiveStarScopeSummary
        ) {
        case .scope:
            AssetScopeInspector(summary: globalFiveStarScopeSummary, assets: globalFiveStarInspectorAssets) {
                inspectorVisible = false
            }
        case .singleGlobalFiveStar(let id):
            if let record = globalFiveStarInspectorRecords.first(where: { $0.id == id }) {
                GlobalFiveStarAssetInspector(store: globalFiveStarStore, record: record) { inspectorVisible = false }
            } else {
                AssetScopeInspector(summary: globalFiveStarScopeSummary, assets: globalFiveStarInspectorAssets) {
                    inspectorVisible = false
                }
            }
        case .multiple(let summary):
            let selectedRecords = globalFiveStarInspectorRecords.filter { summary.globalFiveStarIDs.contains($0.id) }
            GlobalFiveStarBatchInspector(records: selectedRecords, onClearSelection: {
                workspaceSelection.select([])
            }, onClose: {
                inspectorVisible = false
            })
        case .singleFormal, .singlePending, .singleMaterial:
            AssetScopeInspector(summary: globalFiveStarScopeSummary, assets: globalFiveStarInspectorAssets) {
                inspectorVisible = false
            }
        }
    }

    @ViewBuilder private var standardAssetInspector: some View {
        switch ContextualInspectorResolver.resolve(
            selectedIDs: effectiveInspectorSelectedIDs,
            records: inspectorSelectionRecords,
            scope: inspectorScopeSummary
        ) {
        case .scope(let summary):
            AssetScopeInspector(summary: summary, assets: filteredAssets) { inspectorVisible = false }
        case .singleFormal(let id):
            if let asset = store.asset(withID: id) {
                AssetInspector(
                    store: store,
                    asset: asset,
                    onRequestRemoval: { requestRemoval([$0]) },
                    onClose: { inspectorVisible = false }
                )
            } else {
                AssetScopeInspector(summary: inspectorScopeSummary, assets: filteredAssets) { inspectorVisible = false }
            }
        case .singlePending(let galleryID):
            PendingImportInspectorView(
                store: store,
                itemID: pendingGalleryImportID(from: galleryID),
                onHide: { inspectorVisible = false }
            )
        case .multiple(let summary):
            AssetBatchInspector(
                store: store,
                summary: InspectorBatchSummary(
                    formalIDs: summary.formalIDs,
                    pendingIDs: Set(summary.pendingIDs.compactMap { pendingGalleryImportID(from: $0) }),
                    totalFileSize: summary.totalFileSize,
                    missingSourceCount: summary.missingSourceCount
                ),
                onClearSelection: {
                    workspaceSelection.select([])
                },
                onClose: { inspectorVisible = false }
            )
        case .singleGlobalFiveStar, .singleMaterial:
            AssetScopeInspector(summary: inspectorScopeSummary, assets: filteredAssets) { inspectorVisible = false }
        }
    }

    private func requestRemoval(_ galleryIDs: Set<String>) {
        let targets = Set(galleryIDs.map(AssetActionTarget.gallery))
        let plan = AssetRemovalPlan(targets: targets)
        guard plan.totalCount > 0 else { return }
        pendingRemovalPlan = plan
    }

    private func executeRemoval(_ action: AssetRemovalActionDescriptor) {
        switch action.route {
        case .appTrash:
            store.moveAssetsToTrash(action.itemIDs)
            AssetUndoRegistration.registerTrashUndo(
                manager: undoManager,
                store: store,
                assetIDs: action.itemIDs
            )
            workspaceSelection.removeFromSelection(action.itemIDs)
        case .discardPending:
            store.discardPendingImports(action.itemIDs)
            workspaceSelection.removeFromSelection(Set(action.itemIDs.map { "PENDING-\($0)" }))
        case .systemTrashAfterIdentityCheck:
            // Quick Review owns source identity validation and never routes through a gallery action.
            break
        }
        pendingRemovalPlan = nil
    }

    private func chooseWorkspaceImport() {
        if workspaceDestination == .materialLibrary { materialStore.chooseFiles() } else { store.chooseImages() }
    }

    private func importWorkspaceURLs(_ urls: [URL], intoMaterials: Bool? = nil) {
        isDropping = false
        guard !urls.isEmpty else { receivingDrop = false; return }
        receivingDrop = true
        let preferredMaterials = intoMaterials ?? (workspaceDestination == .materialLibrary)
        let projectID = store.currentProject.id
        Task {
            let containsFolder = await Task.detached(priority: .userInitiated) {
                urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }.value
            receivingDrop = false
            if preferredMaterials || containsFolder {
                selectWorkspace(.materialLibrary)
                materialStore.importFiles(urls)
            } else if store.currentProject.id == projectID {
                store.stageImages(urls)
            } else { store.assetActionMessage = "项目已切换，请重新拖入到目标项目" }
        }
    }

    private func importDropped(_ providers: [NSItemProvider]) {
        isDropping = false
        receivingDrop = true
        let intoMaterials = workspaceDestination == .materialLibrary
        let collector = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? String {
                    url = URL(string: value)
                } else {
                    url = nil
                }
                if let url, url.isFileURL { collector.append(url) }
            }
        }
        group.notify(queue: .main) {
            receivingDrop = false
            isDropping = false
            let urls = collector.values()
            guard !urls.isEmpty else {
                store.toast = "未读取到拖入的文件，请从访达重新拖入"
                return
            }
            importWorkspaceURLs(urls, intoMaterials: intoMaterials)
        }
    }

}

struct AssetGalleryView: View {
    let title: String
    @ObservedObject var store: AssetStore
    let assets: [AssetItem]
    let contentVersion: GalleryContentVersion
    @ObservedObject var selectionModel: WorkspaceSelectionModel
    @Binding var layoutMode: AssetGalleryLayoutMode
    @Binding var sort: AssetSortConfiguration
    @Binding var thumbnailWidth: Double
    @Binding var showsName: Bool
    @Binding var showsDescription: Bool
    @Binding var showsSecondaryInfo: Bool
    @Binding var secondaryInfoMode: AssetSecondaryInfoMode
    @Binding var showsExtension: Bool
    @Binding var showsTags: Bool
    @Binding var showsTagCount: Bool
    @Binding var showsRating: Bool
    @Binding var folderScope: LocalFolderScope
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    let folderScopeEnabled: Bool
    let childFolders: [GalleryChildFolder]
    let selectChildFolder: (LocalFolderSelection) -> Void
    let emptyStateKind: QueryAwareEmptyState.Kind
    let clearQuery: () -> Void
    let onRequestRemoval: (Set<String>) -> Void
    @State private var showsComparison = false
    private var cardPresentation: AssetCardPresentation {
        AssetCardPresentation(
            showsName: showsName,
            showsDescription: showsDescription,
            showsSecondaryInfo: showsSecondaryInfo,
            secondaryInfoMode: secondaryInfoMode,
            showsExtension: showsExtension,
            showsTags: showsTags,
            showsTagCount: showsTagCount,
            showsRating: showsRating
        )
    }
    private var galleryContentVersion: GalleryContentVersion {
        contentVersion
    }
    var body: some View {
        ZStack {
            galleryContent
                .opacity(selectionModel.previewID == nil ? 1 : 0)
                .allowsHitTesting(selectionModel.previewID == nil)
                .accessibilityHidden(selectionModel.previewID != nil)

            if selectionModel.previewID != nil {
                EagleGalleryPreview(
                    store: store,
                    assets: assets,
                    selectedAssetID: selectionModel.previewIDBinding,
                    showsSidebar: $showsSidebar,
                    showsInspector: $showsInspector,
                    onSelectionChange: selectPreviewAsset,
                    onClose: closePreview
                )
            }
        }
        .background(GraphiteTheme.canvas)
        .onChange(of: assets.map(\.id)) { _, visibleIDs in
            selectionModel.reconcile(visibleIDs: visibleIDs)
        }
        .onChange(of: contentVersion.viewID) { _, _ in
            selectionModel.clearForContextChange(visibleIDs: assets.map(\.id))
        }
        .sheet(isPresented: $showsComparison) {
            AssetComparisonView(
                store: store,
                assetIDs: comparisonAssetIDs,
                onClose: { showsComparison = false }
            )
        }
    }

    private var galleryContent: some View {
        GalleryWorkspaceShell {
            GalleryHeaderBar(
                title: title,
                assetCount: assets.count,
                selectedCount: selectionModel.selectedIDs.count,
                layoutMode: $layoutMode,
                sort: $sort,
                thumbnailWidth: $thumbnailWidth,
                showsName: $showsName,
                showsDescription: $showsDescription,
                showsSecondaryInfo: $showsSecondaryInfo,
                secondaryInfoMode: $secondaryInfoMode,
                showsExtension: $showsExtension,
                showsTags: $showsTags,
                showsTagCount: $showsTagCount,
                showsRating: $showsRating,
                folderScope: $folderScope,
                showsSidebar: $showsSidebar,
                showsInspector: $showsInspector,
                folderScopeEnabled: folderScopeEnabled,
                chooseLocalFolder: store.chooseLocalFolder
            )
        } content: {
            VStack(spacing: 0) {
            if !selectionModel.selectedIDs.isEmpty {
                selectionCommandBar
                Divider()
            }
            if !childFolders.isEmpty {
                GalleryChildFolderSection(
                    folders: childFolders,
                    folderScope: $folderScope,
                    onSelect: selectChildFolder
                )
                Divider()
            }
            galleryBody
            }
        }
    }

    private var selectionCommandBar: some View {
        ResponsiveCommandBar {
            expandedSelectionActions
        } compact: {
            HStack(spacing: 10) {
                Label("已选 \(selectionModel.selectedIDs.count) 项", systemImage: "checkmark.circle.fill")
                Menu("批量操作", systemImage: "ellipsis.circle") {
                    Button("候选对比", systemImage: "rectangle.split.3x1") { showsComparison = true }
                        .disabled(!canCompareSelection)
                    Divider()
                    Button("加入导出库", systemImage: "shippingbox.badge.plus") { selectResolved(store.performAddToExport(currentTargets)) }
                    Button("加入通用资产", systemImage: "sparkles.rectangle.stack") { selectResolved(store.performSetCommon(true, on: currentTargets)) }
                    Divider()
                    Button(removalButtonTitle, systemImage: "trash", role: .destructive) { onRequestRemoval(selectionModel.selectedIDs) }
                }
                Spacer()
                Button("取消选择") { clearSelection() }.buttonStyle(.borderless)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.bar)
    }

    private var expandedSelectionActions: some View {
        HStack(spacing: 10) {
            Button("候选对比", systemImage: "rectangle.split.3x1") { showsComparison = true }
                .disabled(!canCompareSelection)
                .help("选择 2–4 张正式资产并排比较")
            Button { selectResolved(store.performAddToExport(currentTargets)) } label: { Label("加入导出库", systemImage: "shippingbox.badge.plus") }
            Button { selectResolved(store.performSetCommon(true, on: currentTargets)) } label: { Label("加入通用资产", systemImage: "sparkles.rectangle.stack") }
            Menu { ForEach(AssetType.allCases) { type in Button(type.rawValue) { store.performSetType(type, on: currentTargets) } } } label: { Label("修改类型", systemImage: "tag") }
            Menu { ForEach(UserDecision.allCases) { decision in Button(decision.rawValue) { selectResolved(store.performSetDecision(decision, on: currentTargets)) } } } label: { Label("审核状态", systemImage: "checkmark.circle") }
            Menu {
                Button("清除评分") { selectResolved(store.performSetRating(0, on: currentTargets)) }
                Divider()
                ForEach(1...5, id: \.self) { value in Button("\(value) 星") { selectResolved(store.performSetRating(value, on: currentTargets)) } }
            } label: { Label("评分", systemImage: "star") }
            if !store.availableTags.isEmpty {
                Menu {
                    ForEach(store.availableTags, id: \.self) { tag in Button(tag) { store.performAddTags([tag], on: currentTargets) } }
                } label: { Label("添加标签", systemImage: "tag.fill") }
            }
            Button(role: .destructive) { onRequestRemoval(selectionModel.selectedIDs) } label: { Label(removalButtonTitle, systemImage: "trash") }
            Spacer()
            Button("取消选择") { clearSelection() }.buttonStyle(.borderless)
        }
    }

    private func clearSelection() {
        selectionModel.select([])
    }

    @ViewBuilder private var galleryBody: some View {
        if assets.isEmpty {
            if emptyStateKind == .emptyLibrary {
                QueryAwareEmptyState(
                    kind: .emptyLibrary,
                    primaryActionTitle: "打开项目文件夹",
                    primaryAction: store.chooseProjectFolder,
                    secondaryActionTitle: "链接素材文件夹",
                    secondaryAction: store.chooseLocalFolder
                )
            } else {
                QueryAwareEmptyState(kind: emptyStateKind, clearQuery: clearQuery)
            }
        } else {
            NativeAssetGallery(
                    assets: assets,
                    contentVersion: galleryContentVersion,
                    targetRowHeight: CGFloat(thumbnailWidth),
                    layoutMode: layoutMode,
                    presentation: cardPresentation,
                    contextMenuKind: .standard,
                    dragProjectID: store.currentProject.id,
                    selectedIDs: selectionModel.selectedIDsBinding,
                    onPrimarySelection: { id in
                        selectionModel.selectPrimary(id)
                    },
                    onPreview: previewAsset,
                    onDeleteSelection: onRequestRemoval,
                    onAddToExport: { id in
                        selectResolved(store.performAddToExport([AssetActionTarget.gallery(id)]))
                    },
                    onSetRating: { id, rating in
                        selectResolved(store.performSetRating(rating, on: [AssetActionTarget.gallery(id)]))
                    },
                    onToggleMaster: { id in
                        let resolved = store.resolveFormalTargets([AssetActionTarget.gallery(id)])
                        guard let formalID = resolved.first?.id, let asset = store.asset(withID: formalID) else { return }
                        selectResolved(store.performSetCommon(!asset.isMaster, on: resolved))
                    },
                    onRevealLocation: { store.performReveal(AssetActionTarget.gallery($0)) },
                    onCopyOriginalImage: { store.performCopyOriginal(AssetActionTarget.gallery($0)) },
                    onCopyLocation: { store.performCopyLocation(AssetActionTarget.gallery($0)) },
                    onRelinkFile: { store.performRelink(AssetActionTarget.gallery($0)) },
                    onRenameOriginalFile: { store.performRename(AssetActionTarget.gallery($0)) },
                    projectActionTitle: { _ in nil },
                    onProjectAction: { _ in }
            )
        }
    }

    private func pendingImportID(from galleryID: String) -> String? {
        let prefix = "PENDING-"
        guard galleryID.hasPrefix(prefix) else { return nil }
        return String(galleryID.dropFirst(prefix.count))
    }

    private var currentTargets: Set<AssetActionTarget> {
        Set(selectionModel.selectedIDs.map(AssetActionTarget.gallery))
    }

    private var comparisonAssetIDs: [String] {
        assets.map(\.id).filter { selectionModel.selectedIDs.contains($0) && store.asset(withID: $0) != nil }
    }

    private var canCompareSelection: Bool {
        (2...4).contains(comparisonAssetIDs.count)
    }

    private func selectResolved(_ targets: Set<AssetActionTarget>) {
        guard !targets.isEmpty else { return }
        let galleryIDs = Set(targets.map(\.galleryID))
        let promotedPendingIDs = Set(selectionModel.selectedIDs.filter { AssetActionTarget.gallery($0).capabilities.ratingPromotesToFormal })
        let visibleIDs = assets.map(\.id).filter { !promotedPendingIDs.contains($0) } + Array(galleryIDs)
        selectionModel.reconcile(visibleIDs: visibleIDs)
        selectionModel.select(galleryIDs, primaryID: galleryIDs.count == 1 ? galleryIDs.first : nil)
    }

    private var removalButtonTitle: String {
        let plan = AssetRemovalPlan(targets: Set(selectionModel.selectedIDs.map(AssetActionTarget.gallery)))
        if plan.actions.count == 1, plan.actions.first?.route == .discardPending {
            return "移出待确认"
        }
        return plan.actions.count > 1 ? "处理所选" : "移入回收站"
    }

    private func previewAsset(_ id: String) {
        selectionModel.selectPrimary(id)
        if assets.contains(where: { $0.id == id }) {
            selectionModel.preview(id)
            showsInspector = true
            selectPreviewAsset(id)
        }
    }

    private func selectPreviewAsset(_ id: String) {
        selectionModel.preview(id)
        store.markAssetUsed(id)
    }

    private func closePreview() {
        selectionModel.closePreview()
    }

}

struct AssetGalleryCard: View {
    @ObservedObject var store: AssetStore
    let asset: AssetItem
    @Binding var selectedID: String?
    @State private var isHovered = false

    var body: some View {
        Button { selectedID = asset.id } label: {
            VStack(alignment: .leading, spacing: 8) {
                AssetThumbnail(asset: asset, size: CGSize(width: 216, height: 144), contentMode: .fit, opensPreview: true)
                Text(asset.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)
                    .help(asset.name)
                HStack(spacing: 8) {
                    StatusPill(status: asset.decision)
                    Spacer(minLength: 4)
                    Text(asset.candidatePlan.rawValue).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(height: 24)
                HStack(spacing: 7) {
                    Text(asset.version).font(.caption.weight(.medium))
                    Text(asset.assetDescription.isEmpty ? "点击填写资产说明" : asset.assetDescription)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(height: 18)
            }
            .padding(10)
            .frame(width: 236, height: 272, alignment: .topLeading)
            .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selectedID == asset.id ? Color.accentColor : Color.clear, lineWidth: selectedID == asset.id ? 2 : 0))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(role: .destructive) { moveToTrash() } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered).controlSize(.small).padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("记录优化建议备注…", systemImage: "square.and.pencil") {
                NotificationCenter.default.post(name: .recordOptimizationFeedback, object: nil)
            }
            Divider()
            Button(role: .destructive) { moveToTrash() } label: { Label("移入回收站", systemImage: "trash") }
        }
    }

    private func moveToTrash() {
        store.moveAssetToTrash(asset.id)
        if selectedID == asset.id { selectedID = nil }
    }
}

struct TrashView: View {
    @ObservedObject var store: AssetStore
    let assets: [AssetItem]
    @State private var selectedIDs: Set<String> = []
    @State private var pendingPermanentDeleteIDs: Set<String> = []
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragInitialSelection: Set<String> = []
    @State private var commandDrag = false
    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 290), spacing: 14)]
    private let coordinateSpaceName = "trash-marquee-selection"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("回收站").font(.title2.weight(.semibold))
                    Text("可恢复素材；永久删除只清理软件记录和关联，不动原图").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedIDs.isEmpty {
                    Text("已选择 \(selectedIDs.count) 项").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                    Button("恢复 \(selectedIDs.count) 项", systemImage: "arrow.uturn.backward") { restoreSelected() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("永久删除 \(selectedIDs.count) 项", systemImage: "trash.slash", role: .destructive) {
                        pendingPermanentDeleteIDs = selectedIDs
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button("取消选择") { selectedIDs.removeAll() }
                        .buttonStyle(.borderless).controlSize(.small)
                } else {
                    Text("拖动鼠标左键框选 · ⌘ 点击追加选择")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(assets.count) 项").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            if assets.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash", description: Text("删除的素材会暂存在这里"))
            } else {
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(assets) { asset in
                                trashCard(asset)
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: TrashCardFramePreferenceKey.self,
                                                value: [asset.id: proxy.frame(in: .named(coordinateSpaceName))]
                                            )
                                        }
                                    }
                            }
                        }
                        if let marqueeRect {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.9), lineWidth: 1))
                                .frame(width: marqueeRect.width, height: marqueeRect.height)
                                .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: coordinateSpaceName)
                    .contentShape(Rectangle())
                    .onPreferenceChange(TrashCardFramePreferenceKey.self) { cardFrames = $0 }
                    .simultaneousGesture(marqueeGesture)
                    .padding(16)
                }
            }
        }
        .background(GraphiteTheme.canvas)
        .confirmationDialog(permanentDeleteTitle, isPresented: permanentDeletePresented, titleVisibility: .visible) {
            Button(pendingPermanentDeleteIDs.count > 1 ? "永久删除 \(pendingPermanentDeleteIDs.count) 项" : "永久删除", role: .destructive) {
                let deleting = pendingPermanentDeleteIDs
                store.permanentlyDeleteAssets(deleting)
                selectedIDs.subtract(deleting)
                pendingPermanentDeleteIDs.removeAll()
            }
            Button("取消", role: .cancel) { pendingPermanentDeleteIDs.removeAll() }
        } message: { Text("资产记录、导出库条目和关联将一起删除，无法恢复。用户原始目录中的图片始终不会被删除。") }
        .onChange(of: Set(assets.map(\.id))) { _, validIDs in
            selectedIDs.formIntersection(validIDs)
        }
    }

    private func trashCard(_ asset: AssetItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AssetThumbnail(asset: asset, size: CGSize(width: 250, height: 160), contentMode: .fit, opensPreview: true).frame(maxWidth: .infinity).clipped()
            Text(asset.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Text(asset.deletedAt?.formatted(date: .abbreviated, time: .shortened) ?? "刚刚删除").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button { store.restoreAsset(asset.id); selectedIDs.remove(asset.id) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                Spacer()
                Button(role: .destructive) { pendingPermanentDeleteIDs = [asset.id] } label: { Label("永久删除", systemImage: "trash.slash") }
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(selectedIDs.contains(asset.id) ? Color.accentColor : Color.gray.opacity(0.18), lineWidth: selectedIDs.contains(asset.id) ? 3 : 1))
        .overlay(alignment: .topTrailing) {
            if selectedIDs.contains(asset.id) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture {
            selectedIDs = TrashSelectionLogic.selectionAfterClick(
                id: asset.id,
                current: selectedIDs,
                commandPressed: NSEvent.modifierFlags.contains(.command)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("回收站素材，\(asset.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "选择回收站素材") {
            selectedIDs = TrashSelectionLogic.selectionAfterClick(
                id: asset.id,
                current: selectedIDs,
                commandPressed: false
            )
        }
        .contextMenu {
            Button("记录优化建议备注…", systemImage: "square.and.pencil") {
                NotificationCenter.default.post(name: .recordOptimizationFeedback, object: nil)
            }
            Divider()
            Button { store.restoreAsset(asset.id); selectedIDs.remove(asset.id) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive) { pendingPermanentDeleteIDs = [asset.id] } label: { Label("永久删除", systemImage: "trash.slash") }
        }
    }

    private var permanentDeleteTitle: String {
        if pendingPermanentDeleteIDs.count > 1 { return "永久删除这 \(pendingPermanentDeleteIDs.count) 项素材？" }
        guard let id = pendingPermanentDeleteIDs.first, let asset = store.asset(withID: id) else { return "永久删除素材？" }
        return "永久删除“\(asset.name)”？"
    }
    private var permanentDeletePresented: Binding<Bool> {
        Binding(get: { !pendingPermanentDeleteIDs.isEmpty }, set: { if !$0 { pendingPermanentDeleteIDs.removeAll() } })
    }

    private var marqueeRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return TrashSelectionLogic.rectangle(from: dragStart, to: dragCurrent)
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                    dragInitialSelection = selectedIDs
                    commandDrag = NSEvent.modifierFlags.contains(.command)
                }
                dragCurrent = value.location
                guard let marqueeRect else { return }
                let hits = TrashSelectionLogic.intersectingIDs(in: marqueeRect, frames: cardFrames)
                selectedIDs = TrashSelectionLogic.selectionDuringDrag(
                    initial: dragInitialSelection,
                    intersecting: hits,
                    commandPressed: commandDrag
                )
            }
            .onEnded { _ in
                dragStart = nil
                dragCurrent = nil
                dragInitialSelection.removeAll()
                commandDrag = false
            }
    }

    private func restoreSelected() {
        let restoring = selectedIDs
        store.restoreAssets(restoring)
        selectedIDs.subtract(restoring)
    }
}

struct ExportLibraryView: View {
    @ObservedObject var store: AssetStore
    let assets: [AssetItem]
    let onResolveIssue: (ExportHealthIssue) -> Void
    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 410), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("导出库").font(.title2.weight(.semibold))
                    Text("自动选择可用的最高分辨率原图·不压缩 · \(assets.count) 项").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.chooseExportDestination() } label: { Label("导出四类资产", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(assets.isEmpty)
            }.padding(18)
            Divider()
            exportHealthBar
            if assets.isEmpty {
                ContentUnavailableView("导出库为空", systemImage: "shippingbox", description: Text("在图片画册中多选素材，然后点击“加入导出库”"))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(assets) { asset in exportCard(asset) }
                    }.padding(16)
                }
            }
        }.background(GraphiteTheme.canvas)
    }

    @ViewBuilder private var exportHealthBar: some View {
        let issues = store.exportHealthIssues()
        if !issues.isEmpty, !assets.isEmpty {
            let blockingCount = issues.count { $0.severity == .blocking }
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    blockingCount > 0 ? "\(blockingCount) 项阻塞导出，另有 \(issues.count - blockingCount) 项提醒" : "\(issues.count) 项交付提醒",
                    systemImage: blockingCount > 0 ? "exclamationmark.triangle.fill" : "info.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(blockingCount > 0 ? .orange : .secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(issues) { issue in
                            Button {
                                onResolveIssue(issue)
                            } label: {
                                Label("\(issue.kind.displayName) · \(issue.assetName)", systemImage: issue.kind.systemImage)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("\(issue.message)。点击回到对应资产。")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(blockingCount > 0 ? 0.08 : 0.04))
            Divider()
        }
    }

    private func exportCard(_ asset: AssetItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AssetThumbnail(asset: asset, size: CGSize(width: 112, height: 88), contentMode: .fit, opensPreview: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(asset.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Button { store.removeFromExportLibrary(asset.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("从导出库移除")
                }
                TextField("导出名称", text: exportNameBinding(asset.id))
                    .textFieldStyle(.roundedBorder)
                Text(filenamePreview(asset))
                    .font(.caption2.monospaced()).foregroundStyle(asset.type == .unclassified || asset.sourceMissing ? .orange : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack {
                    Text(exportFolder(asset)).font(.caption.weight(.medium))
                    Spacer()
                    if asset.sourceMissing {
                        Button("重新定位") { store.relinkSource(for: asset.id) }
                            .buttonStyle(.borderless).font(.caption2)
                    }
                    let source = AssetStore.bestAvailableSource(for: asset)
                    Text(source.map { "\($0.resolutionLabel) · \($0.dimensionText)" } ?? "源文件缺失").font(.caption2).foregroundStyle(source == nil ? .orange : .green)
                }
            }
        }
        .padding(12)
        .background(GraphiteTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    private func exportNameBinding(_ id: String) -> Binding<String> {
        Binding(get: { store.exportNames[id] ?? "" }, set: { store.updateExportName(id, name: $0) })
    }

    private func filenamePreview(_ asset: AssetItem) -> String {
        let ext = URL(fileURLWithPath: AssetStore.bestAvailableSource(for: asset)?.path ?? asset.imagePath).pathExtension.lowercased()
        return "\(asset.type.rawValue)_\(store.exportNames[asset.id] ?? asset.name)_\(asset.reuse.rawValue)_\(asset.version).\(ext)"
    }

    private func exportFolder(_ asset: AssetItem) -> String {
        if asset.category == .common { return "通用资产" }
        switch asset.type { case .person, .creature: return "人物资产"; case .venue, .scene: return "场景资产"; default: return "道具资产" }
    }
}

struct EmptyInspector: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("资产详情").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            Divider()
            VStack(spacing: 10) {
                Image(systemName: "cursorarrow.click").font(.largeTitle).foregroundStyle(.tertiary)
                Text("选择一条记录").font(.headline)
                Text("这里会显示素材字段与文件信息").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphiteTheme.inspector)
    }
}
