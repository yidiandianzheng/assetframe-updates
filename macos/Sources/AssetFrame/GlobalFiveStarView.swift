import SwiftUI

struct GlobalFiveStarView: View {
    @ObservedObject var store: GlobalFiveStarStore
    let scope: FiveStarScope
    let project: ProjectRecord
    let category: FiveStarAssetCategory?
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
    @ObservedObject var selectionModel: WorkspaceSelectionModel

    @State private var search = ""
    @State private var selectedType: AssetType?

    private var records: [GlobalFiveStarRecord] {
        let filtered = store.records(scope: scope, projectID: project.id, search: search, type: selectedType, category: category)
        let recordsByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        return AssetQuery.apply(
            to: filtered.map(\.galleryAsset),
            search: "",
            filter: AssetFilter(),
            sort: sort
        ).compactMap { recordsByID[$0.id] }
    }
    private var galleryAssets: [AssetItem] { records.map(\.galleryAsset) }
    private var selectedRecords: [GlobalFiveStarRecord] {
        records.filter { selectionModel.selectedIDs.contains($0.id) }
    }
    private var galleryContentVersion: GalleryContentVersion {
        GalleryContentVersion(
            revision: store.contentRevision,
            viewID: "global-five-star-\(scope.rawValue)-\(project.id)-\(category?.rawValue ?? "all")",
            query: "\(search)|\(selectedType?.rawValue ?? "")|\(category?.rawValue ?? "")|\(sort.cacheKey)"
        )
    }
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

    var body: some View {
        ZStack {
            galleryContent
                .opacity(selectionModel.previewID == nil ? 1 : 0)
                .allowsHitTesting(selectionModel.previewID == nil)
                .accessibilityHidden(selectionModel.previewID != nil)

            if selectionModel.previewID != nil {
                EagleGalleryPreview(
                    assets: galleryAssets,
                    selectedAssetID: selectionModel.previewIDBinding,
                    showsSidebar: $showsSidebar,
                    showsInspector: $showsInspector,
                    onSelectionChange: selectPreviewAsset,
                    onClose: selectionModel.closePreview,
                    onCopyOriginal: copyOriginalImage,
                    onRevealInFinder: reveal
                )
            }
        }
        .background(GraphiteTheme.canvas)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.thickMaterial, in: Capsule())
                    .padding(18)
            }
        }
        .onChange(of: galleryAssets.map(\.id)) { _, visibleIDs in
            selectionModel.reconcile(visibleIDs: visibleIDs)
        }
        .onChange(of: category) { _, _ in
            selectedType = nil
            selectionModel.clearForContextChange(visibleIDs: galleryAssets.map(\.id))
        }
    }

    private var galleryContent: some View {
        GalleryWorkspaceShell {
            GalleryHeaderBar(
                title: galleryTitle,
                assetCount: records.count,
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
                folderScopeEnabled: false,
                showsFolderButton: false,
                chooseLocalFolder: {}
            )
        } content: {
            VStack(spacing: 0) {
            GlobalFiveStarHeader(
                scope: scope,
                projectName: project.name,
                category: category,
                isRefreshing: store.isRefreshing,
                search: $search,
                selectedType: $selectedType
            )
            Divider()
            if !selectionModel.selectedIDs.isEmpty {
                GlobalFiveStarSelectionBar(
                    store: store,
                    records: selectedRecords,
                    project: project,
                    clearSelection: clearSelection
                )
                Divider()
            }
            if records.isEmpty {
                if queryIsActive {
                    QueryAwareEmptyState(kind: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noFilterResults : .noSearchResults) {
                        search = ""
                        selectedType = nil
                    }
                } else {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "star.square.on.square.fill",
                        description: Text(emptyDescription)
                    )
                }
            } else {
                NativeAssetGallery(
                    assets: galleryAssets,
                    contentVersion: galleryContentVersion,
                    targetRowHeight: CGFloat(thumbnailWidth),
                    layoutMode: layoutMode,
                    presentation: cardPresentation,
                    contextMenuKind: .globalFiveStar,
                    dragProjectID: nil,
                    selectedIDs: selectionModel.selectedIDsBinding,
                    onPrimarySelection: selectionModel.selectPrimary,
                    onPreview: preview,
                    onDeleteSelection: { _ in },
                    onAddToExport: { _ in },
                    onSetRating: { _, _ in },
                    onToggleMaster: { _ in },
                    onRevealLocation: reveal,
                    onCopyOriginalImage: copyOriginalImage,
                    onCopyLocation: copyPath,
                    onRelinkFile: { _ in },
                    onRenameOriginalFile: { _ in },
                    projectActionTitle: projectActionTitle,
                    onProjectAction: performProjectAction
                )
            }
            }
        }
    }

    private var galleryTitle: String {
        if scope == .currentProject, let category { return "当前项目资产 · 5 星 · \(category.rawValue)" }
        return scope == .currentProject ? "当前项目资产 · 5 星" : "通用资产"
    }

    private var queryIsActive: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedType != nil
    }

    private var emptyTitle: String {
        if let category { return "当前项目资产还没有五星\(category.rawValue)" }
        return scope == .currentProject ? "当前项目资产还没有五星图片" : "还没有通用资产"
    }

    private var emptyDescription: String {
        if scope == .currentProject {
            if let category { return "评为五星的\(category.rawValue)资产会显示在这里。" }
            return "当前项目评为五星的图片，以及引用到当前项目的通用五星资产，会显示在这里。"
        }
        return "任何评分的资产都可以明确加入通用库；这里只建立跨项目索引，不会移动原图或触发五星 SSD 复制。"
    }

    private func record(withID id: String) -> GlobalFiveStarRecord? {
        records.first { $0.id == id }
    }

    private func preview(_ id: String) {
        guard record(withID: id) != nil else { return }
        selectionModel.preview(id)
        selectPreviewAsset(id)
    }

    private func selectPreviewAsset(_ id: String) {
        selectionModel.preview(id)
    }

    private func reveal(_ id: String) {
        guard let record = record(withID: id) else { return }
        store.reveal(record)
    }

    private func copyPath(_ id: String) {
        guard let record = record(withID: id) else { return }
        store.copyPath(record)
    }

    private func copyOriginalImage(_ id: String) {
        guard let record = record(withID: id) else { return }
        store.copyOriginalImage(record)
    }

    private func projectActionTitle(_ id: String) -> String? {
        guard let record = record(withID: id), !record.isOwned(by: project.id) else { return nil }
        return store.isLinked(id, to: project.id) ? "取消当前项目引用" : "引用到当前项目"
    }

    private func performProjectAction(_ id: String) {
        guard let record = record(withID: id), !record.isOwned(by: project.id) else { return }
        if store.isLinked(id, to: project.id) {
            store.removeLink(recordID: id, projectID: project.id)
        } else {
            store.addLink(recordID: id, projectID: project.id)
        }
    }

    private func clearSelection() { selectionModel.select([]) }
}
