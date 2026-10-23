import AppKit
import SwiftUI

struct GalleryContentVersion: Equatable {
    let revision: UInt64
    let viewID: String
    let query: String
}

@MainActor
struct NativeAssetGallery: NSViewRepresentable {
    @Environment(\.fileImportDropHandler) private var fileImportDropHandler
    let assets: [AssetItem]
    let contentVersion: GalleryContentVersion
    let targetRowHeight: CGFloat
    let layoutMode: AssetGalleryLayoutMode
    let presentation: AssetCardPresentation
    let contextMenuKind: AssetGalleryContextMenuKind
    let dragProjectID: String?
    @Binding var selectedIDs: Set<String>
    let onPrimarySelection: (String?) -> Void
    let onPreview: (String) -> Void
    let onDeleteSelection: (Set<String>) -> Void
    let onAddToExport: (String) -> Void
    let onSetRating: (String, Int) -> Void
    let onToggleMaster: (String) -> Void
    let onRevealLocation: (String) -> Void
    let onCopyOriginalImage: (String) -> Void
    let onCopyLocation: (String) -> Void
    let onRelinkFile: (String) -> Void
    let onRenameOriginalFile: (String) -> Void
    let projectActionTitle: (String) -> String?
    let onProjectAction: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = AssetJustifiedLayout()
        layout.targetRowHeight = targetRowHeight
        layout.metadataHeight = presentation.footerHeight

        let collectionView = AssetNSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = context.coordinator
        collectionView.registerForDraggedTypes([AssetDragPasteboard.type, .fileURL])
        collectionView.onFileDrop = fileImportDropHandler
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.move, forLocal: false)
        collectionView.register(AssetCollectionItem.self, forItemWithIdentifier: AssetCollectionItem.identifier)
        collectionView.onClearSelection = { [weak coordinator = context.coordinator] in coordinator?.clearSelection() }
        collectionView.onRateSelection = { [weak coordinator = context.coordinator] rating in coordinator?.rateSelection(rating) }
        collectionView.onPreviewSelection = { [weak coordinator = context.coordinator] in coordinator?.previewPrimarySelection() }
        collectionView.onDeleteSelection = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
        collectionView.onOpenItem = { [weak coordinator = context.coordinator] indexPath in coordinator?.preview(at: indexPath) }
        collectionView.menuProvider = { [weak coordinator = context.coordinator] indexPath in coordinator?.menu(for: indexPath) }
        collectionView.onSelectionChanged = { [weak coordinator = context.coordinator, weak collectionView] in
            guard let collectionView else { return }
            coordinator?.publishSelection(collectionView)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.install(collectionView: collectionView, scrollView: scrollView)
        context.coordinator.apply(assets: assets, selectedIDs: selectedIDs)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scrollView.documentView as? AssetNSCollectionView)?.onFileDrop = fileImportDropHandler
        context.coordinator.apply(assets: assets, selectedIDs: selectedIDs)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        var parent: NativeAssetGallery
        private weak var collectionView: NSCollectionView?
        private weak var scrollView: NSScrollView?
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var assetsByID: [String: AssetItem] = [:]
        private var orderedIDs: [String] = []
        private var selectionIndex = GallerySelectionIndex(orderedIDs: [])
        private var lastAssetHashes: [String: Int] = [:]
        private var lastContentVersion: GalleryContentVersion?
        private var lastLayoutMode: AssetGalleryLayoutMode?
        private var lastTargetRowHeight: CGFloat?
        private var lastPresentationKey: String?
        private var boundsObserver: NSObjectProtocol?
        private var prefetchWorkItem: DispatchWorkItem?
        private var prefetchRequestIDs: [String: UUID] = [:]

        init(parent: NativeAssetGallery) { self.parent = parent }
        func install(collectionView: NSCollectionView, scrollView: NSScrollView) {
            self.collectionView = collectionView
            self.scrollView = scrollView
            dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collection, indexPath, id in
                MainActor.assumeIsolated {
                    guard let self, let asset = self.assetsByID[id],
                          let item = collection.makeItem(withIdentifier: AssetCollectionItem.identifier, for: indexPath) as? AssetCollectionItem else { return nil }
                    item.configure(
                        asset: asset,
                        selected: self.parent.selectedIDs.contains(id),
                        targetRowHeight: self.parent.targetRowHeight,
                        presentation: self.parent.presentation
                    )
                    return item
                }
            }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePrefetch() }
            }
        }

        func uninstall() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            prefetchWorkItem?.cancel()
            prefetchWorkItem = nil
            for requestID in prefetchRequestIDs.values { ThumbnailPipeline.shared.cancel(requestID) }
            prefetchRequestIDs.removeAll()
        }

        func deleteSelection() {
            guard let collectionView else { return }
            let ids = Set(collectionView.selectionIndexPaths.compactMap { indexPath in
                orderedIDs.indices.contains(indexPath.item) ? orderedIDs[indexPath.item] : nil
            })
            guard !ids.isEmpty else { return }
            parent.onDeleteSelection(ids)
        }

        func apply(assets: [AssetItem], selectedIDs: Set<String>) {
            guard let collectionView, let dataSource else { return }
            let contentChanged = lastContentVersion != parent.contentVersion
            let layoutChanged = lastLayoutMode != parent.layoutMode
                || lastTargetRowHeight != parent.targetRowHeight
            let presentationChanged = lastPresentationKey != parent.presentation.cacheKey

            if contentChanged {
                let previousContentVersion = lastContentVersion
                lastContentVersion = parent.contentVersion
                var nextAssetsByID: [String: AssetItem] = [:]
                var newIDs: [String] = []
                for asset in assets where nextAssetsByID[asset.id] == nil {
                    nextAssetsByID[asset.id] = asset
                    newIDs.append(asset.id)
                }
                assetsByID = nextAssetsByID
                configureLayout(collectionView)
                if let layout = collectionView.collectionViewLayout as? AssetJustifiedLayout {
                    layout.orderedIDs = newIDs
                    layout.targetRowHeight = parent.targetRowHeight
                    layout.metadataHeight = parent.presentation.footerHeight
                    layout.aspectRatios = Dictionary(uniqueKeysWithValues: newIDs.compactMap { id in
                        nextAssetsByID[id].map {
                            (id, AssetJustifiedSizing.aspectRatio(width: $0.pixelWidth, height: $0.pixelHeight))
                        }
                    })
                    layout.invalidateLayout()
                }
                let newHashes = Dictionary(uniqueKeysWithValues: newIDs.compactMap { id in
                    nextAssetsByID[id].map { (id, Self.cardHash($0, presentationKey: parent.presentation.cacheKey)) }
                })

                let currentSnapshot = dataSource.snapshot()
                let snapshotNeedsReplacement = orderedIDs != newIDs
                    || currentSnapshot.sectionIdentifiers != [GallerySnapshotBuilder.sectionID]
                    || currentSnapshot.itemIdentifiers != newIDs

                if snapshotNeedsReplacement {
                    let browsingContextChanged = previousContentVersion?.viewID != parent.contentVersion.viewID
                        || previousContentVersion?.query != parent.contentVersion.query
                    orderedIDs = newIDs
                    selectionIndex = GallerySelectionIndex(orderedIDs: newIDs)
                    (collectionView as? AssetNSCollectionView)?.resetSelectionAnchor()
                    let snapshot = GallerySnapshotBuilder.make(itemIDs: newIDs)
                    dataSource.apply(snapshot, animatingDifferences: false)
                    if browsingContextChanged {
                        scrollView?.contentView.scroll(to: .zero)
                        if let scrollView { scrollView.reflectScrolledClipView(scrollView.contentView) }
                    }
                } else {
                    let changed = newIDs.filter { lastAssetHashes[$0] != newHashes[$0] }
                    if !changed.isEmpty {
                        var snapshot = currentSnapshot
                        let existingIDs = Set(snapshot.itemIdentifiers)
                        let reloadableIDs = changed.filter(existingIDs.contains)
                        if !reloadableIDs.isEmpty {
                            snapshot.reloadItems(reloadableIDs)
                            dataSource.apply(snapshot, animatingDifferences: false)
                        }
                    }
                }
                lastAssetHashes = newHashes
            }

            if !contentChanged, layoutChanged || presentationChanged {
                configureLayout(collectionView)
                if let layout = collectionView.collectionViewLayout as? AssetJustifiedLayout {
                    layout.orderedIDs = orderedIDs
                    layout.targetRowHeight = parent.targetRowHeight
                    layout.metadataHeight = parent.presentation.footerHeight
                    layout.invalidateLayout()
                }
                if presentationChanged, !orderedIDs.isEmpty {
                    var snapshot = dataSource.snapshot()
                    snapshot.reloadItems(orderedIDs)
                    dataSource.apply(snapshot, animatingDifferences: false)
                }
            }
            if contentChanged || layoutChanged || presentationChanged {
                lastLayoutMode = parent.layoutMode
                lastTargetRowHeight = parent.targetRowHeight
                lastPresentationKey = parent.presentation.cacheKey
                schedulePrefetch(immediate: true)
            }

            let indexes = selectionIndex.indexes(for: selectedIDs)
            if collectionView.selectionIndexes != indexes { collectionView.selectionIndexes = indexes }
            for item in collectionView.visibleItems() {
                guard let item = item as? AssetCollectionItem, let id = item.assetID else { continue }
                item.setSelected(selectedIDs.contains(id))
            }
        }

        private func configureLayout(_ collectionView: NSCollectionView) {
            switch parent.layoutMode {
            case .adaptive:
                let layout = (collectionView.collectionViewLayout as? AssetJustifiedLayout) ?? AssetJustifiedLayout()
                layout.targetRowHeight = parent.targetRowHeight
                layout.metadataHeight = parent.presentation.footerHeight
                collectionView.collectionViewLayout = layout
            case .grid:
                let layout = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout) ?? NSCollectionViewFlowLayout()
                let width = max(120, parent.targetRowHeight)
                layout.itemSize = NSSize(width: width, height: width * 0.72 + parent.presentation.footerHeight)
                layout.minimumInteritemSpacing = 10
                layout.minimumLineSpacing = 10
                layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
                collectionView.collectionViewLayout = layout
            }
            collectionView.collectionViewLayout?.invalidateLayout()
        }

        private static func cardHash(_ asset: AssetItem, presentationKey: String) -> Int {
            var hasher = Hasher()
            hasher.combine(asset.id)
            hasher.combine(asset.name)
            hasher.combine(asset.imagePath)
            hasher.combine(asset.sourceModifiedAt)
            hasher.combine(asset.pixelWidth)
            hasher.combine(asset.pixelHeight)
            hasher.combine(asset.starRating)
            hasher.combine(asset.isMaster)
            hasher.combine(asset.thumbnailKey)
            hasher.combine(asset.tags)
            hasher.combine(presentationKey)
            return hasher.finalize()
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { publishSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { publishSelection(collectionView) }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> (any NSPasteboardWriting)? {
            guard let projectID = parent.dragProjectID,
                  let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            let draggedIDs = parent.selectedIDs.contains(id) ? Array(parent.selectedIDs).sorted() : [id]
            let payload = AssetDragPayload(projectID: projectID, assetID: id, assetIDs: draggedIDs)
            guard let data = try? JSONEncoder().encode(payload) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: AssetDragPasteboard.type)
            return item
        }

        func publishSelection(_ collectionView: NSCollectionView) {
            let ids = Set(collectionView.selectionIndexPaths.compactMap { dataSource?.itemIdentifier(for: $0) })
            parent.selectedIDs = ids
            parent.onPrimarySelection(ids.count == 1 ? ids.first : nil)
            for item in collectionView.visibleItems() {
                guard let item = item as? AssetCollectionItem, let id = item.assetID else { continue }
                item.setSelected(ids.contains(id))
            }
        }

        func clearSelection() {
            parent.selectedIDs = []
            parent.onPrimarySelection(nil)
        }

        func previewPrimarySelection() {
            guard let collectionView,
                  let indexPath = collectionView.selectionIndexPaths.sorted(by: { $0.item < $1.item }).first,
                  let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            parent.onPreview(id)
        }

        func preview(at indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            parent.onPreview(id)
        }

        func menu(for indexPath: IndexPath) -> NSMenu? {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            let selectedIDs = Set(collectionView?.selectionIndexPaths.compactMap {
                dataSource?.itemIdentifier(for: $0)
            } ?? [])
            let contextActionIDs = GalleryContextSelection.actionIDs(
                clickedID: id,
                selectedIDs: selectedIDs
            )
            let menu = NSMenu()
            let feedback = NSMenuItem(title: "记录优化建议备注…", action: #selector(recordOptimizationFeedback(_:)), keyEquivalent: "")
            feedback.target = self; menu.addItem(feedback)
            menu.addItem(.separator())
            let preview = NSMenuItem(title: "高清原图预览", action: #selector(previewImage(_:)), keyEquivalent: "")
            preview.target = self; preview.representedObject = id; menu.addItem(preview)
            let copyOriginal = NSMenuItem(title: "复制原图", action: #selector(copyOriginalImage(_:)), keyEquivalent: "")
            copyOriginal.target = self; copyOriginal.representedObject = id; menu.addItem(copyOriginal)
            if parent.contextMenuKind == .standard {
                let add = NSMenuItem(title: "加入导出库", action: #selector(addToExport(_:)), keyEquivalent: "")
                add.target = self; add.representedObject = id; menu.addItem(add)
            }
            if let asset = assetsByID[id] {
                let locations = NSMenu(title: "文件位置")
                addLocationItems(for: asset, to: locations)
                let locationsItem = NSMenuItem(title: "文件位置", action: nil, keyEquivalent: "")
                locationsItem.submenu = locations
                menu.addItem(locationsItem)
            }
            if parent.contextMenuKind == .globalFiveStar {
                if let title = parent.projectActionTitle(id) {
                    menu.addItem(.separator())
                    let projectAction = NSMenuItem(title: title, action: #selector(performProjectAction(_:)), keyEquivalent: "")
                    projectAction.target = self
                    projectAction.representedObject = id
                    menu.addItem(projectAction)
                }
                return menu
            }
            let masterTitle = assetsByID[id]?.isMaster == true ? "移出通用资产" : "加入通用资产"
            let master = NSMenuItem(title: masterTitle, action: #selector(toggleMaster(_:)), keyEquivalent: "")
            master.target = self; master.representedObject = id; menu.addItem(master)
            let ratingMenu = NSMenu(title: "五星评分")
            for value in 0...5 {
                let title = value == 0 ? "清除评分" : "\(value) 星"
                let item = NSMenuItem(title: title, action: #selector(setRating(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["id": id, "rating": value] as NSDictionary
                if assetsByID[id]?.starRating == value { item.state = .on }
                ratingMenu.addItem(item)
                if value == 0 { ratingMenu.addItem(.separator()) }
            }
            let rating = NSMenuItem(title: "五星评分", action: nil, keyEquivalent: "")
            rating.submenu = ratingMenu
            menu.addItem(rating)
            menu.addItem(.separator())
            let removeTitle = contextActionIDs.count > 1
                ? "将 \(contextActionIDs.count) 项移入回收站"
                : "移入回收站"
            let remove = NSMenuItem(title: removeTitle, action: #selector(moveToTrash(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = contextActionIDs.sorted()
            menu.addItem(remove)
            return menu
        }

        @objc private func performProjectAction(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onProjectAction(id) }
        }

        @objc private func moveToTrash(_ sender: NSMenuItem) {
            guard let ids = sender.representedObject as? [String], !ids.isEmpty else { return }
            parent.onDeleteSelection(Set(ids))
        }

        @objc private func recordOptimizationFeedback(_ sender: NSMenuItem) {
            NotificationCenter.default.post(name: .recordOptimizationFeedback, object: nil)
        }

        @objc private func previewImage(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onPreview(id) }
        }

        @objc private func addToExport(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onAddToExport(id) }
        }

        private func addLocationItems(for asset: AssetItem, to menu: NSMenu) {
            let location = AssetFileLocationResolver.location(for: asset)
            if location?.exists == true {
                let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealLocation(_:)), keyEquivalent: "")
                reveal.target = self; reveal.representedObject = asset.id; menu.addItem(reveal)
            }
            if location != nil {
                let copy = NSMenuItem(title: "复制文件路径", action: #selector(copyLocation(_:)), keyEquivalent: "")
                copy.target = self; copy.representedObject = asset.id; menu.addItem(copy)
            }
            if location?.exists == true,
               parent.contextMenuKind == .standard {
                menu.addItem(.separator())
                let rename = NSMenuItem(title: "重命名原文件…", action: #selector(renameOriginalFile(_:)), keyEquivalent: "")
                rename.target = self; rename.representedObject = asset.id; menu.addItem(rename)
            }
            if location?.exists != true {
                let relink = NSMenuItem(title: "重新定位文件…", action: #selector(relinkFile(_:)), keyEquivalent: "")
                relink.target = self; relink.representedObject = asset.id; menu.addItem(relink)
            }
        }

        @objc private func revealLocation(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onRevealLocation(id) }
        }

        @objc private func copyLocation(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onCopyLocation(id) }
        }

        @objc private func copyOriginalImage(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onCopyOriginalImage(id) }
        }

        @objc private func relinkFile(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onRelinkFile(id) }
        }

        @objc private func renameOriginalFile(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onRenameOriginalFile(id) }
        }

        @objc private func toggleMaster(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { parent.onToggleMaster(id) }
        }

        @objc private func setRating(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? NSDictionary,
                  let id = payload["id"] as? String,
                  let rating = payload["rating"] as? Int else { return }
            parent.onSetRating(id, rating)
        }

        func rateSelection(_ rating: Int) {
            guard let collectionView else { return }
            let ids = collectionView.selectionIndexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }
            for id in ids { parent.onSetRating(id, rating) }
        }

        private func prefetchAroundVisibleItems() {
            guard let collectionView, !orderedIDs.isEmpty else { return }
            let visible = collectionView.indexPathsForVisibleItems().map(\.item)
            guard let lower = visible.min(), let upper = visible.max() else { return }
            let range = max(0, lower - 24)...min(orderedIDs.count - 1, upper + 48)
            let assets = range.compactMap { assetsByID[orderedIDs[$0]] }
            let height = max(96, parent.targetRowHeight)
            let desiredIDs = Set(assets.map(\.id))
            let staleIDs = prefetchRequestIDs.keys.filter { !desiredIDs.contains($0) }
            for assetID in staleIDs {
                ThumbnailPipeline.shared.cancel(prefetchRequestIDs.removeValue(forKey: assetID))
            }
            let newAssets = assets.filter { prefetchRequestIDs[$0.id] == nil }
            let newRequests = ThumbnailPipeline.shared.prefetch(
                assets: newAssets,
                size: CGSize(width: height * 1.5, height: height)
            )
            prefetchRequestIDs.merge(newRequests) { current, _ in current }
        }

        private func schedulePrefetch(immediate: Bool = false) {
            prefetchWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.prefetchAroundVisibleItems() }
            }
            prefetchWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.06), execute: workItem)
        }
    }
}

@MainActor
final class AssetNSCollectionView: NSCollectionView {
    var onFileDrop: (@MainActor @Sendable ([URL]) -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if acceptsFileDrop(sender) { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if acceptsFileDrop(sender) { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsFileDrop(sender) || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsFileDrop(sender), let handler = onFileDrop else {
            return super.performDragOperation(sender)
        }
        let urls = FileImportPasteboard.urls(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        // Finish AppKit's drag session before changing/removing the gallery view.
        DispatchQueue.main.async { handler(urls) }
        return true
    }
    private func acceptsFileDrop(_ sender: any NSDraggingInfo) -> Bool {
        onFileDrop != nil && sender.draggingSourceOperationMask.contains(.copy)
            && sender.draggingPasteboard.availableType(from: [.fileURL]) != nil
            && sender.draggingPasteboard.availableType(from: [AssetDragPasteboard.type]) == nil
    }

    var onClearSelection: (() -> Void)?
    var onRateSelection: ((Int) -> Void)?
    var onPreviewSelection: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onOpenItem: ((IndexPath) -> Void)?
    var menuProvider: ((IndexPath) -> NSMenu?)?
    var onSelectionChanged: (() -> Void)?
    private var selectionAnchor: IndexPath?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.shift), let indexPath {
            let current = Set(selectionIndexPaths.map(\.item))
            let resolved = GalleryRangeSelection.indices(
                anchor: selectionAnchor?.item,
                clicked: indexPath.item,
                selected: current,
                itemCount: numberOfItems(inSection: indexPath.section),
                additive: modifiers.contains(.command)
            )
            selectionIndexPaths = Set(resolved.map { IndexPath(item: $0, section: indexPath.section) })
            window?.makeFirstResponder(self)
            scrollToItems(at: [indexPath], scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
            onSelectionChanged?()
            return
        }
        let shouldOpen = event.clickCount == 2
            && modifiers.isEmpty
        super.mouseDown(with: event)
        if let indexPath, selectionIndexPaths.contains(indexPath) {
            selectionAnchor = indexPath
        } else if modifiers.isEmpty {
            selectionAnchor = nil
        }
        if shouldOpen, let indexPath { onOpenItem?(indexPath) }
    }

    func resetSelectionAnchor() {
        selectionAnchor = nil
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        let character = event.charactersIgnoringModifiers?.lowercased()
        if let value = Int(event.charactersIgnoringModifiers ?? ""), (1...5).contains(value), !selectionIndexPaths.isEmpty {
            onRateSelection?(value)
        } else if modifiers.isEmpty,
                  !selectionIndexPaths.isEmpty,
                  event.keyCode == 51 || event.keyCode == 117 || character == "e" {
            onDeleteSelection?()
        } else if event.keyCode == 53 {
            deselectAll(nil)
            selectionAnchor = nil
            onClearSelection?()
        } else if event.keyCode == 49, !selectionIndexPaths.isEmpty {
            onPreviewSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return super.menu(for: event) }
        if !selectionIndexPaths.contains(indexPath) { selectionIndexPaths = [indexPath] }
        return menuProvider?(indexPath)
    }
}

@MainActor
final class AssetCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AssetCollectionItem")

    private let thumbnailView = NSImageView()
    private let checkmarkView = NSImageView()
    private let footerView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let metadataStack = NSStackView()
    private var footerHeightConstraint: NSLayoutConstraint!
    private var requestID: UUID?
    private var thumbnailIdentity: String?
    private(set) var assetID: String?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = GalleryCardChrome.cornerRadius
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0
        view.layer?.borderColor = NSColor.clear.cgColor
        view.layer?.backgroundColor = NSColor.clear.cgColor

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageFrameStyle = .none
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = GalleryCardChrome.cornerRadius
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.borderWidth = 0
        thumbnailView.layer?.borderColor = NSColor.clear.cgColor
        thumbnailView.layer?.backgroundColor = NSColor.clear.cgColor

        checkmarkView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已选择")
        checkmarkView.contentTintColor = .controlAccentColor
        checkmarkView.isHidden = true

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        secondaryLabel.font = .systemFont(ofSize: 10.5)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.lineBreakMode = .byTruncatingTail
        metadataStack.orientation = .vertical
        metadataStack.alignment = .leading
        metadataStack.distribution = .fillEqually
        metadataStack.spacing = 0
        metadataStack.addArrangedSubview(nameLabel)
        metadataStack.addArrangedSubview(secondaryLabel)
        footerView.wantsLayer = true
        footerView.layer?.backgroundColor = NSColor.clear.cgColor

        for subview in [thumbnailView, footerView, checkmarkView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(metadataStack)
        footerHeightConstraint = footerView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerHeightConstraint,
            metadataStack.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 3),
            metadataStack.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 2),
            metadataStack.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -2),
            metadataStack.bottomAnchor.constraint(equalTo: footerView.bottomAnchor, constant: -2),
            checkmarkView.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 7),
            checkmarkView.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: 7),
            checkmarkView.widthAnchor.constraint(equalToConstant: 22),
            checkmarkView.heightAnchor.constraint(equalToConstant: 22)
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        view.layer?.backgroundColor = GalleryCardChrome.backgroundColor(isSelected: isSelected).cgColor
        footerView.layer?.backgroundColor = NSColor.clear.cgColor
        thumbnailView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ThumbnailPipeline.shared.cancel(requestID)
        requestID = nil; thumbnailIdentity = nil; assetID = nil; thumbnailView.image = nil
    }

    func configure(asset: AssetItem, selected: Bool, targetRowHeight: CGFloat, presentation: AssetCardPresentation) {
        updateAppearance()
        assetID = asset.id
        thumbnailView.toolTip = asset.name
        thumbnailView.setAccessibilityLabel(asset.name)
        let previewAspect = AssetJustifiedSizing.aspectRatio(width: asset.pixelWidth, height: asset.pixelHeight)
        footerHeightConstraint.constant = presentation.footerHeight
        nameLabel.stringValue = presentation.displayName(for: asset) ?? ""
        nameLabel.isHidden = presentation.displayName(for: asset) == nil
        secondaryLabel.stringValue = presentation.secondaryText(for: asset) ?? ""
        secondaryLabel.isHidden = presentation.secondaryText(for: asset) == nil
        setSelected(selected)
        let thumbnailSize = CGSize(width: targetRowHeight * previewAspect, height: targetRowHeight)
        let nextIdentity = "\(asset.thumbnailKey ?? asset.imagePath)|\(asset.sourceModifiedAt?.timeIntervalSince1970 ?? 0)|\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))"
        if thumbnailIdentity != nextIdentity {
            thumbnailIdentity = nextIdentity
            ThumbnailPipeline.shared.cancel(requestID)
            thumbnailView.image = nil
            requestID = ThumbnailPipeline.shared.request(asset: asset, size: thumbnailSize) { [weak self] image in
                guard self?.assetID == asset.id, self?.thumbnailIdentity == nextIdentity else { return }
                self?.thumbnailView.image = image
            }
        }
    }

    func setSelected(_ selected: Bool) {
        checkmarkView.isHidden = !selected
        view.layer?.borderWidth = GalleryCardChrome.borderWidth(isSelected: selected)
        view.layer?.borderColor = GalleryCardChrome.borderColor(isSelected: selected).cgColor
        view.layer?.backgroundColor = GalleryCardChrome.backgroundColor(isSelected: selected).cgColor
    }
}

extension Notification.Name {
    static let addAssetsToExportLibrary = Notification.Name("addAssetsToExportLibrary")
    static let previewAssetImage = Notification.Name("previewAssetImage")
}
