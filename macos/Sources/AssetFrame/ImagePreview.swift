import AppKit
import SwiftUI

@MainActor
final class AssetPreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = AssetPreviewWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AssetImagePreview>?

    func show(asset: AssetItem) {
        let preview = AssetImagePreview(asset: asset) { [weak self] in
            self?.window?.performClose(nil)
        }

        if let window, let hostingController {
            hostingController.rootView = preview
            window.title = asset.name
            configureSubtitle(window, asset: asset)
            window.setFrame(preferredFrame(for: asset, on: window.screen), display: true, animate: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let initialFrame = preferredFrame(for: asset, on: screen)
        let hostingController = NSHostingController(rootView: preview)
        let window = AssetPreviewWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = asset.name
        configureSubtitle(window, asset: asset)
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 430, height: 420)
        window.titlebarSeparatorStyle = .none
        window.setFrame(initialFrame, display: true)

        self.hostingController = hostingController
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        hostingController = nil
        window = nil
    }

    private func configureSubtitle(_ window: NSWindow, asset: AssetItem) {
        guard let source = AssetStore.bestAvailableSource(for: asset) else {
            window.subtitle = "源文件缺失"
            return
        }
        window.subtitle = "\(source.resolutionLabel) · \(source.dimensionText)"
    }

    private func preferredFrame(for asset: AssetItem, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1280, height: 820)
        let maximum = visible.insetBy(dx: max(24, visible.width * 0.035), dy: max(24, visible.height * 0.035))
        guard let source = AssetStore.bestAvailableSource(for: asset),
              let pixelWidth = source.pixelWidth, let pixelHeight = source.pixelHeight,
              pixelWidth > 0, pixelHeight > 0 else { return maximum }

        let aspect = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        let titlebarAllowance: CGFloat = 34
        var size: CGSize
        if aspect >= 1 {
            var width = maximum.width
            var height = width / aspect + titlebarAllowance
            if height > maximum.height {
                height = maximum.height
                width = min(maximum.width, (height - titlebarAllowance) * aspect)
            }
            size = CGSize(width: max(760, width), height: max(500, height))
        } else {
            var height = maximum.height
            var width = (height - titlebarAllowance) * aspect
            if width > maximum.width {
                width = maximum.width
                height = min(maximum.height, width / aspect + titlebarAllowance)
            }
            size = CGSize(width: max(480, width), height: max(620, height))
        }
        size.width = min(size.width, maximum.width)
        size.height = min(size.height, maximum.height)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private final class AssetPreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            performClose(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

struct AssetImagePreview: View {
    let asset: AssetItem
    let onClose: () -> Void
    let externalMagnification: Binding<CGFloat>?
    let externalFitToken: Binding<UUID>?
    let showsZoomFooter: Bool
    @State private var selectedSourceID: String
    @State private var image: NSImage?
    @State private var decodedPixelSize: CGSize?
    @State private var isLoading = true
    @State private var magnification: CGFloat = 1
    @State private var fitToken = UUID()
    @State private var wantsFullResolution = false
    private var usesTiles: Bool { LargeImagePolicy.needsTiles(width: source?.pixelWidth, height: source?.pixelHeight) }

    private var availableSources: [AssetSourceVersion] {
        asset.allSourceVersions
            .filter { !$0.path.isEmpty && FileManager.default.fileExists(atPath: $0.path) }
            .sorted {
                if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
                return ($0.fileSize ?? 0) > ($1.fileSize ?? 0)
            }
    }

    private var source: AssetSourceVersion? {
        availableSources.first(where: { $0.id == selectedSourceID }) ?? availableSources.first ?? asset.allSourceVersions.first(where: { !$0.path.isEmpty })
    }

    init(
        asset: AssetItem,
        onClose: @escaping () -> Void = {},
        externalMagnification: Binding<CGFloat>? = nil,
        externalFitToken: Binding<UUID>? = nil,
        showsZoomFooter: Bool = true
    ) {
        self.asset = asset
        self.onClose = onClose
        self.externalMagnification = externalMagnification
        self.externalFitToken = externalFitToken
        self.showsZoomFooter = showsZoomFooter
        let best = AssetStore.bestAvailableSource(for: asset)
        _selectedSourceID = State(initialValue: best?.id ?? "")
    }

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let source, URL(fileURLWithPath: source.path).pathExtension.lowercased() == "svg" {
                SVGOriginalPreview(url: URL(fileURLWithPath: source.path), magnification: magnificationBinding, fitToken: activeFitToken)
            } else if let image, let source {
                ZoomableOriginalImage(
                    image: image,
                    sourceURL: URL(fileURLWithPath: source.path),
                    pixelSize: usesTiles ? CGSize(width: source.pixelWidth ?? Int(image.size.width), height: source.pixelHeight ?? Int(image.size.height)) : decodedPixelSize ?? image.size,
                    usesTiles: usesTiles,
                    magnification: magnificationBinding,
                    fitToken: activeFitToken,
                    traceIdentity: asset.id
                )
            } else if isLoading {
                VStack(spacing: 12) { ProgressView(); Text("正在生成快速预览…").foregroundStyle(.secondary) }
            } else {
                ContentUnavailableView("无法预览原图", systemImage: "photo.badge.exclamationmark", description: Text("可在资产详情中重新定位原图"))
            }
            VStack(spacing: 0) {
                compactMetadata
                Spacer()
                if showsZoomFooter {
                    footer.padding(.bottom, 14)
                }
            }
        }
        .frame(minWidth: 430, minHeight: 420)
        .task(id: "\(selectedSourceID)|\(wantsFullResolution)") {
            await loadSource(fullResolution: wantsFullResolution)
        }
        .onChange(of: selectedSourceID) { _, _ in
            wantsFullResolution = false
            setMagnification(1)
        }
        .onChange(of: currentMagnification) { _, value in
            if value >= 0.99 { wantsFullResolution = true }
        }
        .onExitCommand(perform: onClose)
    }

    private var compactMetadata: some View {
        HStack(spacing: 12) {
            if let source {
                HStack(spacing: 7) {
                    Text(source.resolutionLabel).fontWeight(.bold).foregroundStyle(resolutionColor(source.resolutionLabel))
                    Text(source.dimensionText)
                    Text("ESC 退出")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThickMaterial, in: Capsule())
            }
            Spacer()
            if availableSources.count > 1 {
                Picker("原图版本", selection: $selectedSourceID) {
                    ForEach(availableSources) { candidate in
                        Text("\(candidate.resolutionLabel) · \(candidate.dimensionText) · \(candidate.filename)").tag(candidate.id)
                    }
                }
                .frame(maxWidth: 300)
            }
            Label(usesTiles ? "超大图 · 按可见区域加载细节" : "快速预览 · 1:1 显示原图细节", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThickMaterial, in: Capsule())
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { setMagnification(max(0.05, currentMagnification / 1.25)) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int((currentMagnification * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 52)
            Button { setMagnification(min(8, currentMagnification * 1.25)) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("1:1") { setMagnification(1) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("适合窗口") { requestFitToWindow() }
                .keyboardShortcut("0", modifiers: [.command])
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .fixedSize()
    }

    private var magnificationBinding: Binding<CGFloat> {
        externalMagnification ?? $magnification
    }

    private var currentMagnification: CGFloat {
        externalMagnification?.wrappedValue ?? magnification
    }

    private var activeFitToken: UUID {
        externalFitToken?.wrappedValue ?? fitToken
    }

    private func setMagnification(_ value: CGFloat) {
        magnificationBinding.wrappedValue = value
    }

    private func requestFitToWindow() {
        if let externalFitToken {
            externalFitToken.wrappedValue = UUID()
        } else {
            fitToken = UUID()
        }
    }

    @MainActor
    private func loadSource(fullResolution: Bool) async {
        guard let source else { image = nil; isLoading = false; return }
        if URL(fileURLWithPath: source.path).pathExtension.lowercased() == "svg" { isLoading = false; return }
        isLoading = true
        let request = PreviewImageRequest(
            path: source.path,
            sourceIdentity: "\(source.id)|\(source.fileSize ?? 0)",
            sourceWidth: source.pixelWidth,
            sourceHeight: source.pixelHeight,
            sourceFileSize: source.fileSize,
            sourceModifiedAt: source.modifiedAt,
            allowSourceRead: FileManager.default.fileExists(atPath: source.path),
            priority: .visiblePreview
        )
        let viewportSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_280, height: 820)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        if image == nil {
            let small = await PreviewImagePipeline.shared.loadAsync(
                request: request, viewportSize: CGSize(width: 256, height: 256), backingScale: 2, fullResolution: false)
            guard !Task.isCancelled, self.source?.id == source.id else { return }
            image = small.image
            decodedPixelSize = small.pixelSize
        }
        let loaded = await PreviewImagePipeline.shared.loadAsync(
            request: request, viewportSize: viewportSize, backingScale: backingScale, fullResolution: fullResolution && !usesTiles && request.allowSourceRead)
        guard !Task.isCancelled, self.source?.id == source.id else { return }
        image = loaded.image ?? image
        decodedPixelSize = loaded.pixelSize ?? decodedPixelSize
        isLoading = false
        if !fullResolution { fitToken = UUID() }
    }

    private func resolutionColor(_ label: String) -> Color {
        switch label { case "4K": .purple; case "2K": .blue; case "1K": .green; default: .orange }
    }
}

private struct ZoomableOriginalImage: NSViewRepresentable {
    let image: NSImage
    let sourceURL: URL
    let pixelSize: CGSize
    let usesTiles: Bool
    @Binding var magnification: CGFloat
    let fitToken: UUID
    var traceIdentity: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OriginalImageScrollView {
        let scrollView = OriginalImageScrollView()
        scrollView.onMagnificationChanged = { value in
            Task { @MainActor in if abs(magnification - value) > 0.001 { magnification = value } }
        }
        configure(scrollView, coordinator: context.coordinator, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: OriginalImageScrollView, context: Context) {
        configure(scrollView, coordinator: context.coordinator, force: false)
        if context.coordinator.lastFitToken != fitToken {
            context.coordinator.lastFitToken = fitToken
            scrollView.requestFitToWindow()
        } else if abs(scrollView.magnification - magnification) > 0.001 {
            scrollView.setRequestedMagnification(magnification)
        }
    }
    static func dismantleNSView(_ scrollView: OriginalImageScrollView, coordinator: Coordinator) { scrollView.stopTiles() }

    private func configure(_ scrollView: OriginalImageScrollView, coordinator: Coordinator, force: Bool) {
        scrollView.sourceURL = sourceURL
        scrollView.traceIdentity = traceIdentity
        let identity = "\(sourceURL.path)|\(ObjectIdentifier(image))|\(pixelSize.width)x\(pixelSize.height)|\(usesTiles)"
        guard force || coordinator.imageIdentity != identity else { return }
        coordinator.imageIdentity = identity
        scrollView.setImage(image, pixelSize: pixelSize, tiles: usesTiles ? sourceURL : nil)
    }

    final class Coordinator {
        var imageIdentity = ""
        var lastFitToken: UUID?
    }
}

private final class TracedPreviewImageView: NSImageView {
    var traceIdentity: String?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard image != nil, window != nil, let traceIdentity else { return }
        BrowsePerformanceTrace.completePreview(traceIdentity)
    }
}

private final class OriginalImageScrollView: NSScrollView {
    private var tileOverlay: OriginalTileOverlay?
    private let originalImageView: NSImageView = BrowsePerformanceTrace.enabled
        ? TracedPreviewImageView() : NSImageView()
    var traceIdentity: String? {
        get { (originalImageView as? TracedPreviewImageView)?.traceIdentity }
        set { (originalImageView as? TracedPreviewImageView)?.traceIdentity = newValue }
    }
    private var keepsImageFitted = true
    private var lastViewportSize = CGSize.zero
    private var fittedMagnification: CGFloat = 1
    private var dragStartWindowLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var pushedClosedHandCursor = false
    var onMagnificationChanged: ((CGFloat) -> Void)?
    var sourceURL: URL?
    private var isCopyingOriginal = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        let centeringClipView = CenteringClipView()
        centeringClipView.drawsBackground = true
        centeringClipView.backgroundColor = .underPageBackgroundColor
        contentView = centeringClipView
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 8
        originalImageView.imageScaling = .scaleProportionallyUpOrDown
        originalImageView.wantsLayer = true
        documentView = originalImageView
        let originalMenu = NSMenu()
        for (title, action) in [
            ("复制原图", #selector(copyOriginalImage)),
            ("在 Finder 中显示原图", #selector(revealOriginalImage)),
            ("复制文件路径", #selector(copyOriginalPath)),
            ("用默认应用打开", #selector(openOriginalImage))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            originalMenu.addItem(item)
        }
        menu = originalMenu
        contentView.menu = originalMenu
        originalImageView.menu = originalMenu
    }

    @objc private func copyOriginalImage() {
        guard let sourceURL, !isCopyingOriginal else { return }
        isCopyingOriginal = true
        Task { @MainActor in
            defer { isCopyingOriginal = false }
            do {
                try await OriginalImageClipboard.copyImageInBackground(at: sourceURL)
            } catch {
                showOriginalActionError(error.localizedDescription)
            }
        }
    }

    @objc private func revealOriginalImage() {
        guard let url = existingOriginalURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyOriginalPath() {
        guard let sourceURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sourceURL.path, forType: .string)
    }

    @objc private func openOriginalImage() {
        guard let url = existingOriginalURL() else { return }
        if !NSWorkspace.shared.open(url) {
            showOriginalActionError("无法用默认应用打开原图，请检查文件或默认应用设置。")
        }
    }

    private func existingOriginalURL() -> URL? {
        guard let sourceURL else { return nil }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            showOriginalActionError("原图文件已移动或磁盘未连接。")
            return nil
        }
        return sourceURL
    }

    private func showOriginalActionError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "原图操作失败"
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: canPan ? .openHand : .arrow)
    }

    override func layout() {
        super.layout()
        let viewportSize = stableViewportSize
        guard keepsImageFitted,
              viewportSize.width > 1,
              viewportSize.height > 1,
              viewportSize != lastViewportSize else { return }
        lastViewportSize = viewportSize
        applyFitMagnification(viewportSize: viewportSize)
    }

    var visibleCenterInDocument: NSPoint {
        NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
    }

    func setImage(_ image: NSImage, pixelSize: CGSize, tiles: URL? = nil) {
        tileOverlay?.stop(); tileOverlay?.removeFromSuperview(); tileOverlay = nil
        originalImageView.image = image
        originalImageView.frame = NSRect(origin: .zero, size: NSSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height)))
        documentView = originalImageView
        if let tiles, let renderer = OriginalTileRenderer(url: tiles) {
            originalImageView.frame.size = renderer.size
            let overlay = OriginalTileOverlay(renderer: renderer)
            originalImageView.addSubview(overlay); tileOverlay = overlay
        }
        requestFitToWindow()
    }
    func stopTiles() { tileOverlay?.stop(); tileOverlay?.removeFromSuperview(); tileOverlay = nil }

    func requestFitToWindow() {
        keepsImageFitted = true
        lastViewportSize = .zero
        needsLayout = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard self.keepsImageFitted else { return }
            self.layoutSubtreeIfNeeded()
            let viewportSize = self.stableViewportSize
            guard viewportSize.width > 1, viewportSize.height > 1 else { return }
            self.lastViewportSize = viewportSize
            self.applyFitMagnification(viewportSize: viewportSize)
        }
    }

    func setRequestedMagnification(_ value: CGFloat) {
        keepsImageFitted = false
        setMagnification(value, centeredAt: visibleCenterInDocument)
        refreshPanCursor()
    }

    private var stableViewportSize: CGSize {
        // `bounds` is expressed in magnified document coordinates and changes
        // every time zoom changes. `frame` remains the actual visible viewport.
        contentView.frame.size
    }

    private func applyFitMagnification(viewportSize: CGSize) {
        guard originalImageView.frame.width > 0, originalImageView.frame.height > 0 else { return }
        let value = PreviewZoomMath.fitMagnification(
            imageSize: originalImageView.frame.size,
            viewportSize: viewportSize,
            minimumMagnification: minMagnification,
            maximumMagnification: maxMagnification
        )
        fittedMagnification = value
        setMagnification(value, centeredAt: NSPoint(x: originalImageView.frame.midX, y: originalImageView.frame.midY))
        onMagnificationChanged?(value)
        refreshPanCursor()
    }

    override func magnify(with event: NSEvent) {
        keepsImageFitted = false
        super.magnify(with: event)
        onMagnificationChanged?(magnification)
        refreshPanCursor()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            keepsImageFitted = false
            let delta = event.scrollingDeltaY
            let factor = pow(1.08, delta > 0 ? 1 : -1)
            let next = min(maxMagnification, max(minMagnification, magnification * factor))
            let point = documentView?.convert(event.locationInWindow, from: nil) ?? visibleCenterInDocument
            setMagnification(next, centeredAt: point)
            onMagnificationChanged?(next)
            refreshPanCursor()
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            toggleDetailZoom(at: event.locationInWindow)
            return
        }
        guard canPan else {
            super.mouseDown(with: event)
            return
        }
        // Keep drag deltas in the window's non-flipped coordinate space.
        // Converting through NSScrollView can invert the vertical axis and make
        // grab-to-pan feel opposite to Eagle on one direction.
        dragStartWindowLocation = event.locationInWindow
        dragStartOrigin = contentView.bounds.origin
        NSCursor.closedHand.push()
        pushedClosedHandCursor = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWindowLocation, let dragStartOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let currentLocation = event.locationInWindow
        let translation = CGSize(
            width: currentLocation.x - dragStartWindowLocation.x,
            height: currentLocation.y - dragStartWindowLocation.y
        )
        let nextOrigin = PreviewPanMath.draggedOrigin(
            startOrigin: dragStartOrigin,
            viewportTranslation: translation,
            magnification: magnification
        )
        contentView.scroll(to: nextOrigin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    override func mouseExited(with event: NSEvent) {
        endDrag()
        super.mouseExited(with: event)
    }

    private var canPan: Bool {
        let visible = documentVisibleRect
        return originalImageView.frame.width > visible.width + 1 || originalImageView.frame.height > visible.height + 1
    }

    private func toggleDetailZoom(at windowPoint: NSPoint) {
        if abs(magnification - fittedMagnification) < 0.01 {
            keepsImageFitted = false
            let documentPoint = documentView?.convert(windowPoint, from: nil) ?? visibleCenterInDocument
            setMagnification(1, centeredAt: documentPoint)
            onMagnificationChanged?(1)
            refreshPanCursor()
        } else {
            requestFitToWindow()
        }
    }

    private func endDrag() {
        dragStartWindowLocation = nil
        dragStartOrigin = nil
        if pushedClosedHandCursor {
            NSCursor.pop()
            pushedClosedHandCursor = false
        }
        refreshPanCursor()
    }

    private func refreshPanCursor() {
        window?.invalidateCursorRects(for: self)
    }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }

        if documentView.frame.width < proposedBounds.width {
            constrained.origin.x = (documentView.frame.width - proposedBounds.width) / 2
        }
        if documentView.frame.height < proposedBounds.height {
            constrained.origin.y = (documentView.frame.height - proposedBounds.height) / 2
        }
        return constrained
    }
}
