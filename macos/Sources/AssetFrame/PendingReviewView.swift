import SwiftUI

struct PendingReviewView: View {
    @ObservedObject var store: AssetStore
    let scopedIDs: [String]?
    @State private var queue: PendingReviewQueue
    @State private var isDeletingSource = false
    @State private var isShowingDiscardedOnly = false
    @State private var typeSelection = PendingReviewTypeSelection()
    @State private var showsVisionAPISettings = false
    @State private var showsAIUploadConfirmation = false
    @State private var showsAIReview = false
    @State private var pendingAIConfiguration: VisionAPIConfiguration?
    @State private var pendingAITargetIDs: [String] = []
    @State private var pendingSingleTrashID: String?

    init(
        store: AssetStore,
        scopedIDs: [String]?
    ) {
        self.store = store
        self.scopedIDs = scopedIDs
        let ids = scopedIDs ?? store.pendingImports.map(\.id)
        let preferredID = ids.first { id in
            store.pendingImport(withID: id)?.effectiveReviewStatus == .unreviewed
        }
        _queue = State(initialValue: PendingReviewQueue(itemIDs: ids, preferredID: preferredID))
    }

    private var scopedItems: [PendingImportItem] {
        let byID = Dictionary(uniqueKeysWithValues: store.pendingImports.map { ($0.id, $0) })
        let ids = scopedIDs ?? store.pendingImports.map(\.id)
        return ids.compactMap { byID[$0] }
    }

    private var items: [PendingImportItem] {
        let statusItems: [PendingImportItem]
        if isShowingDiscardedOnly {
            statusItems = scopedItems.filter { $0.effectiveReviewStatus == .discarded }
        } else {
            statusItems = scopedItems
        }
        return statusItems.filter(typeSelection.includes)
    }

    private var itemIDs: [String] {
        items.map(\.id)
    }

    private var currentItem: PendingImportItem? {
        guard let currentID = queue.currentID else { return nil }
        return items.first { $0.id == currentID }
    }

    private var keptCount: Int {
        scopedItems.count { $0.effectiveReviewStatus == .kept }
    }

    private var discardedIDs: Set<String> {
        Set(scopedItems.lazy.filter {
            $0.effectiveReviewStatus == .discarded
        }.map(\.id))
    }

    private var unreviewedCount: Int {
        scopedItems.count { $0.effectiveReviewStatus == .unreviewed }
    }

    private var availableReviewTags: [String] {
        Array(Set(store.availableTags + store.pendingImports.flatMap(\.normalizedManualTags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var availableTypes: [AssetType] {
        let types = Set(scopedItems.map(\.suggestedType))
        return AssetType.allCases.filter(types.contains)
    }

    private var aiEligibleIDs: [String] {
        scopedItems.filter {
            $0.suggestedType == .unclassified &&
            $0.effectiveReviewStatus != .discarded &&
            $0.aiVisionSuggestion == nil
        }.map(\.id)
    }

    private var aiPendingSuggestionCount: Int {
        scopedItems.count {
            $0.aiVisionSuggestion?.effectiveDecision == .pending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PendingReviewHeader(
                currentPosition: (queue.currentIndex ?? 0) + (items.isEmpty ? 0 : 1),
                totalCount: items.count,
                allItemCount: scopedItems.count,
                keptCount: keptCount,
                discardedCount: discardedIDs.count,
                unreviewedCount: unreviewedCount,
                isShowingDiscardedOnly: isShowingDiscardedOnly,
                aiEligibleCount: aiEligibleIDs.count,
                aiPendingSuggestionCount: aiPendingSuggestionCount,
                isAIAnalyzing: store.pendingAIClassificationProgress?.phase == .analyzing,
                onAIOrganize: prepareAIClassification,
                onShowAIReview: { showsAIReview = true },
                onKeepAllUnreviewed: keepAllUnreviewed,
                onToggleDiscardedOnly: toggleDiscardedOnly,
                onImportKept: store.confirmKeptPendingImports,
                onTrashDiscarded: trashDiscardedSources,
                actionsDisabled: store.isImporting || isDeletingSource
            )
            PendingReviewTypeFilterBar(
                availableTypes: availableTypes,
                selectedTypes: typeSelection.selectedTypes,
                currentType: currentItem?.suggestedType,
                filteredCount: items.count,
                totalCount: isShowingDiscardedOnly ? discardedIDs.count : scopedItems.count,
                countForType: countForType,
                onToggleType: toggleType,
                onSelectOnly: selectOnlyType,
                onClear: clearTypeFilter
            )
            if let currentItem {
                HSplitView {
                    PendingReviewPreview(
                        item: currentItem,
                        onOpenOriginal: { AssetPreviewWindowController.shared.show(asset: currentItem.previewAsset) }
                    )
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    PendingReviewClassificationPanel(
                        item: currentItem,
                        generationBatch: store.generationBatch(for: currentItem),
                        availableTags: availableReviewTags,
                        onNameChange: {
                            store.updatePendingImport(currentItem.id, preferredName: $0)
                        },
                        onTypeChange: { store.updatePendingImport(currentItem.id, type: $0) },
                        onCategoryChange: { store.updatePendingImport(currentItem.id, category: $0) },
                        onTagsChange: { store.updatePendingImport(currentItem.id, manualTags: $0) }
                    )
                    .id(currentItem.id)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: .infinity)
                }
                PendingReviewFilmstrip(
                    items: items,
                    currentID: queue.currentID,
                    onSelect: { queue.select($0) },
                    onSetStatus: { id, status in
                        store.setPendingReviewStatus(id, status: status)
                    },
                    onRevealOriginal: { store.revealPendingImportSource($0) }
                )
                PendingReviewActionBar(
                    canSelectPrevious: (queue.currentIndex ?? 0) > 0,
                    canSelectNext: (queue.currentIndex ?? -1) + 1 < items.count,
                    isCurrentKept: currentItem.effectiveReviewStatus == .kept,
                    isCurrentDiscarded: currentItem.effectiveReviewStatus == .discarded,
                    isBusy: isDeletingSource || store.isImporting,
                    onPrevious: { queue.selectPrevious() },
                    onNext: { queue.selectNext() },
                    onKeep: keepCurrent,
                    onTrash: requestTrashCurrentSource
                )
            } else {
                ContentUnavailableView(
                    isShowingDiscardedOnly
                        ? "没有已标记的废片"
                        : (store.pendingImports.isEmpty ? "筛图队列已处理完" : "本批筛图已完成"),
                    systemImage: isShowingDiscardedOnly ? "eye.slash" : "checkmark.rectangle.stack.fill",
                    description: Text(
                        isShowingDiscardedOnly
                            ? "选择“查看全部”返回当前批次继续筛图。"
                            : "已保留的图片可登记为正式资产；未判断的其他批次仍留在快速筛图。"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: prefetchAroundCurrent)
        .onChange(of: itemIDs) { _, ids in
            queue.replaceItems(with: ids)
            prefetchAroundCurrent()
        }
        .onChange(of: queue.currentID) { _, _ in
            prefetchAroundCurrent()
        }
        .onDisappear(perform: cancelPrefetch)
        .sheet(isPresented: $showsVisionAPISettings) {
            VisionAPISettingsView(
                onSave: { configuration in
                    pendingAIConfiguration = configuration
                    showsVisionAPISettings = false
                    showsAIUploadConfirmation = true
                },
                onCancel: { showsVisionAPISettings = false }
            )
        }
        .sheet(isPresented: $showsAIReview) {
            PendingAIReviewSheet(
                store: store,
                scopedIDs: scopedItems.map(\.id),
                onReanalyze: reanalyzeAIItems,
                onClose: { showsAIReview = false }
            )
        }
        .confirmationDialog(
            "将图片预览发送到视觉 API？",
            isPresented: $showsAIUploadConfirmation,
            titleVisibility: .visible
        ) {
            Button("发送并分析 \(pendingAITargetIDs.count) 张", action: startAIClassification)
            Button("取消", role: .cancel) {
                pendingAIConfiguration = nil
                pendingAITargetIDs = []
            }
        } message: {
            Text("每张图片只发送最长边 1280px 的 JPEG 预览、文件名、项目内相对目录和本机分类标签。不会发送原图、绝对路径、数据库或文件指纹。")
        }
        .confirmationDialog(
            "将此原图移到 macOS 废纸篓？",
            isPresented: Binding(
                get: { pendingSingleTrashID != nil },
                set: { if !$0 { pendingSingleTrashID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("核验后移到系统废纸篓", role: .destructive) {
                guard let id = pendingSingleTrashID else { return }
                pendingSingleTrashID = nil
                trashPendingSource(id)
            }
            Button("取消", role: .cancel) { pendingSingleTrashID = nil }
        } message: {
            Text("仅当原文件的大小和修改时间仍与导入记录一致时才会移动；核验失败时原文件和待确认记录都会保留。")
        }
    }

    private func keepCurrent() {
        guard let currentItem else { return }
        store.setPendingReviewStatus(currentItem.id, status: .kept)
        queue.selectNext()
    }

    private func requestTrashCurrentSource() {
        guard let currentItem, !isDeletingSource else { return }
        pendingSingleTrashID = currentItem.id
    }

    private func trashPendingSource(_ id: String) {
        guard !isDeletingSource else { return }
        isDeletingSource = true
        Task {
            _ = await store.trashPendingImportSource(id)
            isDeletingSource = false
        }
    }

    private func keepAllUnreviewed() {
        let ids = Set(scopedItems.lazy.filter {
            $0.effectiveReviewStatus == .unreviewed
        }.map(\.id))
        store.keepUnreviewedPendingImports(ids)
    }

    private func toggleDiscardedOnly() {
        let showsDiscardedOnly = !isShowingDiscardedOnly
        isShowingDiscardedOnly = showsDiscardedOnly
        let ids = showsDiscardedOnly
            ? scopedItems.filter { $0.effectiveReviewStatus == .discarded }.map(\.id)
            : scopedItems.map(\.id)
        queue.replaceItems(with: ids, preferredID: ids.first)
        prefetchAroundCurrent()
    }

    private func countForType(_ type: AssetType) -> Int {
        scopedItems.count {
            $0.suggestedType == type &&
            (!isShowingDiscardedOnly || $0.effectiveReviewStatus == .discarded)
        }
    }

    private func toggleType(_ type: AssetType) {
        typeSelection.toggle(type)
    }

    private func selectOnlyType(_ type: AssetType) {
        typeSelection.selectOnly(type)
    }

    private func clearTypeFilter() {
        typeSelection.clear()
    }

    private func trashDiscardedSources() {
        let ids = discardedIDs
        guard !ids.isEmpty, !isDeletingSource else { return }
        isDeletingSource = true
        Task {
            _ = await store.trashDiscardedPendingImports(ids)
            isDeletingSource = false
        }
    }

    private func prefetchAroundCurrent() {
        guard let index = queue.currentIndex, !items.isEmpty else { return }

        // 当前、后两张与前一张先准备屏幕级预览。用户连续筛图时，大图请求会直接命中缓存。
        let screenIndexes = [index, index + 1, index + 2, index - 1].filter(items.indices.contains)
        let screenAssets = screenIndexes.map { items[$0].previewAsset }
        ThumbnailPipeline.shared.prefetch(
            assets: screenAssets,
            size: CGSize(width: 1_024, height: 1_024)
        )

        let lower = max(0, index - 4)
        let upper = min(items.count - 1, index + 12)
        let assets = items[lower...upper].map(\.previewAsset)
        ThumbnailPipeline.shared.prefetch(
            assets: assets,
            size: CGSize(width: 108, height: 74)
        )
    }

    private func cancelPrefetch() {}

    private func prepareAIClassification() {
        pendingAITargetIDs = aiEligibleIDs
        guard !pendingAITargetIDs.isEmpty else { return }
        if let configuration = VisionAPISettings.storedConfiguration() {
            pendingAIConfiguration = configuration
            showsAIUploadConfirmation = true
        } else {
            showsVisionAPISettings = true
        }
    }

    private func startAIClassification() {
        guard let configuration = pendingAIConfiguration, !pendingAITargetIDs.isEmpty else { return }
        store.startPendingAIClassification(ids: pendingAITargetIDs, configuration: configuration)
        pendingAIConfiguration = nil
        pendingAITargetIDs = []
        showsAIReview = true
    }

    private func reanalyzeAIItems(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        guard let configuration = VisionAPISettings.storedConfiguration() else {
            pendingAITargetIDs = ids
            showsAIReview = false
            showsVisionAPISettings = true
            return
        }
        store.startPendingAIClassification(ids: ids, configuration: configuration)
    }
}
