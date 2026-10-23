import SwiftUI

struct EagleGalleryPreview: View {
    let assets: [AssetItem]
    @Binding var selectedAssetID: String?
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    let onSelectionChange: (String) -> Void
    let onClose: () -> Void
    let onCopyOriginal: (String) -> Void
    let onRevealInFinder: (String) -> Void
    let onAddToExportLibrary: ((String) -> Void)?

    @FocusState private var acceptsKeyboardNavigation: Bool
    @State private var magnification: CGFloat = 1
    @State private var fitToken = UUID()
    @State private var previewDirection = 1

    init(
        store: AssetStore,
        assets: [AssetItem],
        selectedAssetID: Binding<String?>,
        showsSidebar: Binding<Bool>,
        showsInspector: Binding<Bool>,
        onSelectionChange: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.assets = assets
        _selectedAssetID = selectedAssetID
        _showsSidebar = showsSidebar
        _showsInspector = showsInspector
        self.onSelectionChange = onSelectionChange
        self.onClose = onClose
        onCopyOriginal = { _ = store.copyOriginalImage(for: $0) }
        onRevealInFinder = { _ = store.revealFileLocation(for: $0) }
        onAddToExportLibrary = { store.addToExportLibrary([$0]) }
    }

    init(
        assets: [AssetItem],
        selectedAssetID: Binding<String?>,
        showsSidebar: Binding<Bool>,
        showsInspector: Binding<Bool>,
        onSelectionChange: @escaping (String) -> Void,
        onClose: @escaping () -> Void,
        onCopyOriginal: @escaping (String) -> Void,
        onRevealInFinder: @escaping (String) -> Void,
        onAddToExportLibrary: ((String) -> Void)? = nil
    ) {
        self.assets = assets
        _selectedAssetID = selectedAssetID
        _showsSidebar = showsSidebar
        _showsInspector = showsInspector
        self.onSelectionChange = onSelectionChange
        self.onClose = onClose
        self.onCopyOriginal = onCopyOriginal
        self.onRevealInFinder = onRevealInFinder
        self.onAddToExportLibrary = onAddToExportLibrary
    }

    private var selectedIndex: Int? {
        guard let selectedAssetID else { return nil }
        return assets.firstIndex(where: { $0.id == selectedAssetID })
    }

    private var selectedAsset: AssetItem? {
        guard let selectedIndex else { return nil }
        return assets[selectedIndex]
    }

    private var canSelectPrevious: Bool {
        guard let selectedIndex else { return false }
        return selectedIndex > assets.startIndex
    }

    private var canSelectNext: Bool {
        guard let selectedIndex else { return false }
        return selectedIndex + 1 < assets.endIndex
    }

    var body: some View {
        VStack(spacing: 0) {
            previewToolbar
            Divider()
            if let selectedAsset {
                AssetImagePreview(
                    asset: selectedAsset,
                    onClose: onClose,
                    externalMagnification: $magnification,
                    externalFitToken: $fitToken,
                    showsZoomFooter: false
                )
                .id(selectedAsset.id)
            } else {
                ContentUnavailableView(
                    "图片已不在当前结果中",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("返回画册后可以重新选择图片")
                )
            }
        }
        .background(GraphiteTheme.canvas)
        .focusable()
        .focused($acceptsKeyboardNavigation)
        .onAppear { acceptsKeyboardNavigation = true }
        .onMoveCommand(perform: handleMoveCommand)
        .onExitCommand(perform: onClose)
        .onChange(of: assets.map(\.id)) { _, assetIDs in
            guard let selectedAssetID, !assetIDs.contains(selectedAssetID) else { return }
            onClose()
        }
        .onChange(of: selectedAssetID) { _, _ in
            magnification = 1
            fitToken = UUID()
        }
        .task(id: selectedAssetID) {
            guard let index = selectedIndex else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let neighbors = [index + previewDirection, index - previewDirection].filter { assets.indices.contains($0) }.map { assets[$0] }
            let viewport = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 820)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let worker = Task.detached(priority: .utility) {
                for asset in neighbors {
                    guard !Task.isCancelled else { return }
                    guard ImportResumeRecord.availableLocally(URL(fileURLWithPath: asset.imagePath)) else { continue }
                    let request = PreviewImageRequest(path: asset.imagePath, sourceIdentity: asset.id, sourceWidth: asset.pixelWidth, sourceHeight: asset.pixelHeight, priority: .utility)
                    _ = PreviewImagePipeline.shared.load(request: request, viewportSize: viewport, backingScale: scale, fullResolution: false)
                }
            }
            await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("大图查看")
    }

    private var previewToolbar: some View {
        EaglePreviewToolbar(
            selectedIndex: selectedIndex,
            assetCount: assets.count,
            filename: selectedAsset.map { $0.originalFilename.isEmpty ? $0.name : $0.originalFilename },
            magnification: $magnification,
            showsSidebar: $showsSidebar,
            showsInspector: $showsInspector,
            canSelectPrevious: canSelectPrevious,
            canSelectNext: canSelectNext,
            onClose: onClose,
            onFitToWindow: { fitToken = UUID() },
            onActualSize: { magnification = 1 },
            onCopyOriginal: copyOriginal,
            onRevealInFinder: revealInFinder,
            showsExportAction: onAddToExportLibrary != nil,
            onAddToExportLibrary: addToExportLibrary,
            onSelectPrevious: selectPrevious,
            onSelectNext: selectNext
        )
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: selectPrevious()
        case .right: selectNext()
        default: break
        }
    }

    private func selectPrevious() {
        guard let selectedIndex, selectedIndex > assets.startIndex else { return }
        selectAsset(at: selectedIndex - 1)
    }

    private func selectNext() {
        guard let selectedIndex, selectedIndex + 1 < assets.endIndex else { return }
        selectAsset(at: selectedIndex + 1)
    }

    private func selectAsset(at index: Int) {
        guard assets.indices.contains(index) else { return }
        if let current = selectedIndex { previewDirection = index < current ? -1 : 1 }
        let id = assets[index].id
        selectedAssetID = id
        onSelectionChange(id)
    }

    private func copyOriginal() {
        guard let selectedAssetID else { return }
        onCopyOriginal(selectedAssetID)
    }

    private func revealInFinder() {
        guard let selectedAssetID else { return }
        onRevealInFinder(selectedAssetID)
    }

    private func addToExportLibrary() {
        guard let selectedAssetID else { return }
        onAddToExportLibrary?(selectedAssetID)
    }
}
