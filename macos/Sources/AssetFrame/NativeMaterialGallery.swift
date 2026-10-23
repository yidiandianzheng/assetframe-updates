import AppKit
import SwiftUI

/// Keep SwiftUI card graphs limited to reusable, visible collection items.
@MainActor
struct NativeMaterialGallery<Card: View>: NSViewRepresentable {
    @Environment(\.fileImportDropHandler) private var fileImportDropHandler
    let records: [MaterialRecord]
    let selectedIDs: Set<String>
    let actionContext: String
    /// A stable parent supplied revision for the rendered query result. When nil,
    /// the coordinator uses the records and IDs as a compatibility fallback.
    var contentRevision: UInt64? = nil
    /// Changes when the user changes browse scope, filters, search, or sorting.
    /// Data-only updates such as imports deliberately keep the current position.
    var navigationIdentity = ""
    var scrollPosition: Binding<Double>? = nil
    var scrollAnchor: Binding<LibraryScrollAnchor?>? = nil
    var isBrowsing = true
    var proportional = false
    var thumbnailSize: Double = 165
    var captionHeight: Double = 32
    var onClick: ((MaterialRecord, NSEvent.ModifierFlags, Bool) -> Void)? = nil
    let card: (MaterialRecord) -> Card

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private static func makeCollection() -> AssetNSCollectionView {
        let collection = AssetNSCollectionView()
        // A newly restored gallery starts at zero width before SwiftUI places
        // its scroll view. Follow the clip view instead of retaining that width.
        collection.autoresizingMask = [.width]
        collection.collectionViewLayout = NSCollectionViewFlowLayout()
        collection.backgroundColors = [.clear]
        collection.register(MaterialCollectionItem<Card>.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("material-card"))
        collection.registerForDraggedTypes([.fileURL])
        return collection
    }

    func makeNSView(context: Context) -> NSScrollView {
        let collection = Self.makeCollection()
        collection.onFileDrop = fileImportDropHandler
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.install(collection)
        context.coordinator.apply()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (view.documentView as? AssetNSCollectionView)?.onFileDrop = fileImportDropHandler
        context.coordinator.apply()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDelegate {
        var parent: NativeMaterialGallery
        private weak var collection: NSCollectionView?
        private var source: NSCollectionViewDiffableDataSource<Int, String>?
        private var contentIndex = GalleryContentIndex<MaterialRecord>()
        private var byID: [String: MaterialRecord] = [:]
        private var orderedIDs: [String] = []
        private var selected: Set<String> = []
        private var actionContext = ""
        private var geometryKey = ""
        private var navigationIdentity = ""
        private var lastContentRevision: UInt64?
        private var hasAppliedContent = false
        private var snapshotApplying = false
        private var applyAgainAfterSnapshot = false
        private var collectionGeneration: UInt64 = 0

        private struct ScrollAnchor {
            let id: String
            let offset: CGFloat
            let absoluteY: CGFloat
        }
        private var anchorsByNavigationKey: [String: ScrollAnchor] = [:]
        private var navigationKeyOrder: [String] = []
        private let maximumNavigationHistory = 100

        nonisolated(unsafe) private var observer: NSObjectProtocol?
        private var didRestore = false
        private var wasBrowsing = true
        private var needsBrowseRestore = false
        private var positionTask: Task<Void, Never>?
        private var prefetchTask: Task<Void, Never>?
        private var prefetchIdentity = ""
        private var lastScrollY: CGFloat = 0
        private var scrollDirection = 1
        init(parent: NativeMaterialGallery) { self.parent = parent; super.init() }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func stop() {
            if let collection, didRestore, wasBrowsing { saveAnchor(for: navigationIdentity, in: collection) }
            positionTask?.cancel(); positionTask = nil
            prefetchTask?.cancel(); prefetchTask = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        func install(_ collection: NSCollectionView) {
            prefetchTask?.cancel(); prefetchTask = nil; prefetchIdentity = ""
            BrowsePerformanceTrace.startSampling()
            collectionGeneration &+= 1
            snapshotApplying = false
            applyAgainAfterSnapshot = false
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            self.collection = collection
            collection.delegate = self
            if let clip = collection.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                    MainActor.assumeIsolated {
                        guard let self, let clip, self.didRestore, self.parent.isBrowsing, !self.needsBrowseRestore else { return }
                        BrowsePerformanceTrace.record("scroll_bounds", fields: ["y": Double(clip.bounds.origin.y)])
                        let y = clip.bounds.origin.y
                        if abs(y - self.lastScrollY) > 1 {
                            self.scrollDirection = y < self.lastScrollY ? -1 : 1
                            GlobalMaterialStore.noteBrowseInteraction()
                        }
                        self.lastScrollY = y
                        self.positionTask?.cancel()
                        self.positionTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(100))
                            guard !Task.isCancelled, let self, self.parent.isBrowsing, !self.needsBrowseRestore, let collection = self.collection else { return }
                            self.saveAnchor(for: self.navigationIdentity, in: collection)
                        }
                        self.schedulePrefetch()
                    }
                }
            }
            source = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, indexPath, id in
                guard let self, let record = self.byID[id],
                      let item = collection.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("material-card"), for: indexPath) as? MaterialCollectionItem<Card> else { return nil }
                self.configure(item, record: record)
                return item
            }
        }

        func apply() {
            let applyStart = DispatchTime.now().uptimeNanoseconds
            defer { BrowsePerformanceTrace.emit("gallery_apply", since: applyStart, fields: ["records": orderedIDs.count]) }
            guard var collection = collection, var source = source else { return }
            if parent.isBrowsing && !wasBrowsing { needsBrowseRestore = true }
            if !parent.isBrowsing && wasBrowsing {
                saveAnchor(for: navigationIdentity, in: collection, force: true)
                positionTask?.cancel(); positionTask = nil
                prefetchTask?.cancel(); prefetchTask = nil; prefetchIdentity = ""
            }
            wasBrowsing = parent.isBrowsing
            if snapshotApplying {
                applyAgainAfterSnapshot = true
                return
            }
            let key = "\(parent.proportional)|\(parent.thumbnailSize)|\(parent.captionHeight)"
            let selectionChanges = selected.symmetricDifference(parent.selectedIDs)
            let contextChanged = actionContext != parent.actionContext
            let previousNavigationIdentity = navigationIdentity
            let navigationChanged = hasAppliedContent && previousNavigationIdentity != parent.navigationIdentity
            actionContext = parent.actionContext
            navigationIdentity = parent.navigationIdentity
            selected = parent.selectedIDs

            // A supplied revision is the fast path: do not rebuild the dictionary
            // or ordered ID array on every SwiftUI update. The nil path compares
            // values so older callers remain correct.
            let revisionChanged = !hasAppliedContent || parent.contentRevision != lastContentRevision
            // With a non-nil revision the parent owns content invalidation. Do
            // not scan records or map IDs on ordinary SwiftUI updates. Nil is
            // the compatibility path for legacy callers and remains value-safe.
            let shouldRebuildIndex = revisionChanged || parent.contentRevision == nil
            let previousRecords = byID
            let changedRecordIDs = contentIndex.update(parent.records, revision: parent.contentRevision)
            let rebuiltIDs: [String]? = shouldRebuildIndex ? contentIndex.orderedIDs : nil
            if shouldRebuildIndex { byID = contentIndex.byID }
            let IDsChanged = rebuiltIDs.map { $0 != orderedIDs } ?? false
            if parent.isBrowsing && !needsBrowseRestore && hasAppliedContent && (navigationChanged || revisionChanged || geometryKey != key || IDsChanged) {
                saveAnchor(for: navigationChanged ? previousNavigationIdentity : navigationIdentity, in: collection)
            }
            let nextIDs = rebuiltIDs ?? orderedIDs
            let renderedIDsChanged = nextIDs != orderedIDs
            // Rating, name, tags and usage timestamps repaint cards without
            // rebuilding every frame or resetting the scroll anchor.
            let aspectRatiosChanged = parent.proportional && changedRecordIDs.contains { id in
                // New memberships are already covered by renderedIDsChanged.
                // Only geometry changes to retained cards exclude insert reuse.
                guard let old = previousRecords[id], let new = byID[id] else { return false }
                return old.kind != new.kind
                    || old.mediaMetadata?.pixelWidth != new.mediaMetadata?.pixelWidth
                    || old.mediaMetadata?.pixelHeight != new.mediaMetadata?.pixelHeight
            }
            let geometryChanged = geometryKey != key
            let layoutChanged = geometryChanged || renderedIDsChanged || aspectRatiosChanged
            let insertionOnly = renderedIDsChanged && hasAppliedContent
                && GalleryMembershipUpdatePolicy.canInsertInPlace(
                    previousIDs: orderedIDs, nextIDs: nextIDs,
                    firstPopulation: orderedIDs.isEmpty && previousNavigationIdentity.isEmpty,
                    navigationChanged: navigationChanged, geometryChanged: geometryChanged,
                    aspectRatiosChanged: aspectRatiosChanged)
            if insertionOnly {
                // Clear every owned hosted surface, including retained AppKit
                // item containers which are no longer reported as visible.
                // The diff completion repopulates the current visible items.
                for item in collection.visibleItems() {
                    (item as? MaterialCollectionItem<Card>)?.discardPresentation()
                }
                scrubHostedSurfaces(in: collection)
            }
            if hasAppliedContent && renderedIDsChanged && !insertionOnly,
               let scroll = collection.enclosingScrollView {
                // AppKit may retain outgoing hosted item views even after a
                // nonanimated diff plus reloadData. Replace the document view
                // atomically so no old cards can remain under the new result.
                // Keep this coordinator's navigation anchors and content index.
                let replacement = NativeMaterialGallery.makeCollection()
                BrowsePerformanceTrace.record("gallery_container_replace", fields: ["old_count": orderedIDs.count, "new_count": nextIDs.count])
                replacement.frame = NSRect(origin: .zero, size: collection.frame.size)
                replacement.onFileDrop = (collection as? AssetNSCollectionView)?.onFileDrop
                collection.delegate = nil
                collection.dataSource = nil
                scroll.documentView = replacement
                didRestore = false
                install(replacement)
                collection = replacement
                guard let replacementSource = self.source else { return }
                source = replacementSource
            }
            if layoutChanged {
                geometryKey = key
                configureLayout(collection, orderedIDs: nextIDs)
            }
            if renderedIDsChanged {
                orderedIDs = nextIDs
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(nextIDs)
                // The custom layout has already changed its index-to-frame map.
                // Diffing against old items can leave outgoing hosted cards at
                // their previous frames behind the new folder's cards. Reload
                // membership atomically; metadata-only updates remain in place.
                if insertionOnly {
                    snapshotApplying = true
                    let generation = collectionGeneration
                    BrowsePerformanceTrace.record("gallery_in_place_insert", fields: ["new_count": nextIDs.count])
                    source.apply(snapshot, animatingDifferences: false) { [weak self, weak collection] in
                        guard let self, let collection,
                              self.collectionGeneration == generation, self.collection === collection else { return }
                        collection.collectionViewLayout?.invalidateLayout()
                        self.restoreAnchor(for: self.navigationIdentity, in: collection,
                            resetToTop: navigationChanged && self.anchorsByNavigationKey[self.navigationIdentity] == nil)
                        for path in collection.indexPathsForVisibleItems() {
                            guard let id = self.source?.itemIdentifier(for: path), let record = self.byID[id],
                                  let item = collection.item(at: path) as? MaterialCollectionItem<Card> else { continue }
                            self.configure(item, record: record)
                        }
                        self.hideOrphanedSurfaces(in: collection)
                        self.snapshotApplying = false
                        BrowsePerformanceTrace.emit("gallery_snapshot_complete", since: applyStart)
                        if self.applyAgainAfterSnapshot {
                            self.applyAgainAfterSnapshot = false
                            Task { @MainActor [weak self] in self?.apply() }
                        }
                    }
                } else {
                    source.apply(snapshot, animatingDifferences: false) {
                        BrowsePerformanceTrace.emit("gallery_snapshot_complete", since: applyStart)
                    }
                    BrowsePerformanceTrace.record("gallery_full_reload")
                    collection.reloadData()
                    collection.collectionViewLayout?.invalidateLayout()
                }
            } else if geometryChanged || aspectRatiosChanged {
                // Recreate visible item geometry after resizing or aspect changes.
                BrowsePerformanceTrace.record("gallery_full_reload")
                collection.reloadData()
            }
            for index in collection.indexPathsForVisibleItems() where !insertionOnly {
                guard let id = source.itemIdentifier(for: index), let record = byID[id],
                      contextChanged || geometryChanged || changedRecordIDs.contains(id) || selectionChanges.contains(id),
                      let item = collection.item(at: index) as? MaterialCollectionItem<Card> else { continue }
                configure(item, record: record)
            }
            if !insertionOnly && !nextIDs.isEmpty && (layoutChanged || navigationChanged || !didRestore) { restoreAnchor(for: navigationIdentity, in: collection, resetToTop: navigationChanged && anchorsByNavigationKey[navigationIdentity] == nil) }
            lastContentRevision = parent.contentRevision
            hasAppliedContent = true
            if needsBrowseRestore && parent.isBrowsing {
                let generation = collectionGeneration
                DispatchQueue.main.async { [weak self, weak collection] in
                    guard let self, let collection, self.parent.isBrowsing, self.collectionGeneration == generation else { return }
                    self.restoreAnchor(for: self.navigationIdentity, in: collection, resetToTop: false)
                    self.needsBrowseRestore = false
                    self.schedulePrefetch()
                }
            } else { schedulePrefetch() }
            if !selectionChanges.isEmpty { BrowsePerformanceTrace.completeSelection() }
        }

        private func schedulePrefetch() {
            guard parent.isBrowsing, !needsBrowseRestore, let collection, !snapshotApplying, !orderedIDs.isEmpty else { return }
            let visible = collection.indexPathsForVisibleItems().map(\.item)
            guard let first = visible.min(), let last = visible.max(), last < orderedIDs.count else { return }
            let ahead = scrollDirection > 0 ? Array((last + 1)..<min(orderedIDs.count, last + 9))
                : Array(max(0, first - 8)..<first).reversed().map { $0 }
            let behind = scrollDirection > 0 ? Array(max(0, first - 4)..<first).reversed().map { $0 }
                : Array((last + 1)..<min(orderedIDs.count, last + 5))
            let requests = (ahead + behind).compactMap { index -> PreviewImageRequest? in
                guard orderedIDs.indices.contains(index), let record = byID[orderedIDs[index]], record.kind == .image,
                      let path = AssetFileLocationResolver.canonicalMaterialPath(for: record) ?? record.sourceURL else { return nil }
                return PreviewImageRequest(path: path, sourceIdentity: "\(record.id)|\(record.sourceModifiedAt?.timeIntervalSince1970 ?? 0)",
                    sourceWidth: record.mediaMetadata?.pixelWidth, sourceHeight: record.mediaMetadata?.pixelHeight,
                    sourceFileSize: record.fileSize, sourceModifiedAt: record.sourceModifiedAt, priority: .utility)
            }
            let pixels = min(512, (min(1600, max(256, parent.thumbnailSize * 1.94)) / 256).rounded(.up) * 256)
            let identity = "\(SSDPreviewCache.root.path)|\(pixels)|" + requests.map { "\($0.path)|\($0.sourceIdentity)|\($0.sourceFileSize ?? 0)" }.joined(separator: "\n")
            guard identity != prefetchIdentity else { return }
            prefetchIdentity = identity
            BrowsePerformanceTrace.record("gallery_prefetch_schedule", fields: ["count": requests.count, "direction": scrollDirection])
            prefetchTask?.cancel()
            prefetchTask = Task.detached(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(120))
                for request in requests {
                    guard !Task.isCancelled else { return }
                    guard ImportResumeRecord.availableLocally(URL(fileURLWithPath: request.path)) else { continue }
                    _ = await PreviewImagePipeline.shared.loadAsync(request: request,
                        viewportSize: CGSize(width: pixels, height: pixels), backingScale: 1, fullResolution: false)
                }
            }
        }

        private func configure(_ item: MaterialCollectionItem<Card>, record: MaterialRecord) {
            let handler: ((NSEvent) -> Void)? = parent.onClick == nil ? nil : { [weak self] event in
                guard let self else { return }
                self.parent.onClick?(record, event.modifierFlags, event.clickCount == 2)
            }
            item.configure(parent.card(record), representedID: record.id, onClick: handler)
        }

        private func scrubHostedSurfaces(in root: NSView) {
            if let owned = root as? MaterialCardContainer {
                owned.subviews.forEach { $0.removeFromSuperview() }
                owned.onClick = nil
                return
            }
            root.subviews.forEach { scrubHostedSurfaces(in: $0) }
        }
        private func hideOrphanedSurfaces(in collection: NSCollectionView) {
            let valid = Set(collection.visibleItems().map { ObjectIdentifier($0.view) })
            var hidden = 0
            func visit(_ view: NSView) {
                if let owned = view as? MaterialCardContainer {
                    if !valid.contains(ObjectIdentifier(owned)),
                       owned.convert(owned.bounds, to: collection).intersects(collection.visibleRect) {
                        owned.isHidden = true
                        owned.subviews.forEach { $0.removeFromSuperview() }
                        hidden += 1
                    }
                    return
                }
                view.subviews.forEach(visit)
            }
            visit(collection)
            BrowsePerformanceTrace.record("gallery_surface_audit", fields: ["orphan_surfaces_hidden": hidden, "visible_items": valid.count])
        }

        private func configureLayout(_ collection: NSCollectionView, orderedIDs: [String]) {
            if parent.proportional {
                let layout = (collection.collectionViewLayout as? AssetJustifiedLayout) ?? AssetJustifiedLayout()
                layout.orderedIDs = orderedIDs
                layout.aspectRatios = Dictionary(uniqueKeysWithValues: orderedIDs.compactMap { id in
                    byID[id].map { material in
                        (id, AssetJustifiedSizing.aspectRatio(
                            width: material.mediaMetadata?.pixelWidth,
                            height: material.mediaMetadata?.pixelHeight,
                            fallback: fallbackAspectRatio(for: material.kind)
                        ))
                    }
                })
                layout.targetRowHeight = parent.thumbnailSize
                layout.metadataHeight = parent.captionHeight + 12
                if collection.collectionViewLayout !== layout { collection.collectionViewLayout = layout }
                layout.invalidateLayout()
            } else {
                let layout = (collection.collectionViewLayout as? NSCollectionViewFlowLayout) ?? NSCollectionViewFlowLayout()
                layout.itemSize = NSSize(
                    width: parent.thumbnailSize,
                    height: parent.thumbnailSize + parent.captionHeight + 12
                )
                layout.minimumInteritemSpacing = AssetJustifiedSizing.spacing
                layout.minimumLineSpacing = AssetJustifiedSizing.spacing
                layout.sectionInset = NSEdgeInsets(
                    top: AssetJustifiedSizing.verticalInset,
                    left: AssetJustifiedSizing.horizontalInset,
                    bottom: AssetJustifiedSizing.verticalInset,
                    right: AssetJustifiedSizing.horizontalInset
                )
                if collection.collectionViewLayout !== layout { collection.collectionViewLayout = layout }
                layout.invalidateLayout()
            }
        }

        private func fallbackAspectRatio(for kind: MaterialKind) -> CGFloat {
            switch kind {
            case .document: 0.74
            case .video: 16.0 / 9.0
            case .audio: 1.6
            case .image: 1.0
            case .font, .projectFile, .link, .other: 1.0
            }
        }

        private func saveAnchor(for navigationKey: String, in collection: NSCollectionView, force: Bool = false) {
            guard (parent.isBrowsing || force), !orderedIDs.isEmpty else { return }
            guard let scroll = collection.enclosingScrollView,
                  let layout = collection.collectionViewLayout else { return }
            let y = scroll.contentView.bounds.origin.y
            let candidate = layout.layoutAttributesForElements(in: NSRect(x: 0, y: y, width: collection.bounds.width, height: max(1, scroll.contentView.bounds.height)))
                .filter { $0.indexPath?.section == 0 }
                .min { abs($0.frame.minY - y) < abs($1.frame.minY - y) }
            let anchor: ScrollAnchor
            if let candidate, let indexPath = candidate.indexPath, let id = source?.itemIdentifier(for: indexPath) {
                anchor = ScrollAnchor(id: id, offset: y - candidate.frame.minY, absoluteY: y)
            } else {
                // A viewport can fall in a layout gap; preserve its absolute
                // position so a refresh still has a useful fallback.
                anchor = ScrollAnchor(id: "", offset: y, absoluteY: y)
            }
            anchorsByNavigationKey[navigationKey] = anchor
            parent.scrollPosition?.wrappedValue = Double(y)
            if !anchor.id.isEmpty {
                parent.scrollAnchor?.wrappedValue = LibraryScrollAnchor(materialID: anchor.id,
                    offset: Double(anchor.offset), navigationIdentity: navigationKey)
            }
            navigationKeyOrder.removeAll { $0 == navigationKey }
            navigationKeyOrder.append(navigationKey)
            if navigationKeyOrder.count > maximumNavigationHistory {
                let expired = navigationKeyOrder.removeFirst()
                anchorsByNavigationKey.removeValue(forKey: expired)
            }
        }

        private func restoreAnchor(for navigationKey: String, in collection: NSCollectionView, resetToTop: Bool) {
            guard parent.isBrowsing else { return }
            guard let scroll = collection.enclosingScrollView else { return }
            collection.layoutSubtreeIfNeeded()
            let persisted = parent.scrollAnchor?.wrappedValue
            let restored = persisted.flatMap { value -> ScrollAnchor? in
                guard value.navigationIdentity == navigationKey else { return nil }
                return ScrollAnchor(id: value.materialID, offset: CGFloat(value.offset), absoluteY: CGFloat(parent.scrollPosition?.wrappedValue ?? 0))
            }
            let shouldReset = resetToTop && restored == nil
            let anchor = shouldReset ? nil : (anchorsByNavigationKey[navigationKey] ?? restored)
            let y: CGFloat
            if let anchor, !anchor.id.isEmpty,
               let indexPath = source?.indexPath(for: anchor.id),
               let attributes = collection.collectionViewLayout?.layoutAttributesForItem(at: indexPath) {
                y = attributes.frame.minY + anchor.offset
            } else if let anchor {
                y = anchor.absoluteY
            } else {
                y = shouldReset ? 0 : CGFloat(parent.scrollPosition?.wrappedValue ?? 0)
            }
            BrowsePerformanceTrace.record("gallery_anchor_restore", fields: ["material_id": anchor?.id ?? "", "target_y": Double(y), "reset": resetToTop])
            let maxY = max(0, collection.frame.height - scroll.contentView.bounds.height)
            let clamped = min(max(0, y), maxY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            scroll.reflectScrolledClipView(scroll.contentView)
            parent.scrollPosition?.wrappedValue = Double(clamped)
            didRestore = true
        }
    }
}

@MainActor
private final class MaterialCollectionItem<Card: View>: NSCollectionViewItem {
    private var hosting: NSHostingView<Card>?
    private var representedID: String?
    override func loadView() {
        view = MaterialCardContainer()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
    }
    func configure(_ card: Card, representedID: String, onClick: ((NSEvent) -> Void)?) {
        view.isHidden = false
        if hosting?.superview !== view { hosting = nil }
        if self.representedID != representedID {
            hosting?.removeFromSuperview()
            hosting = nil
        }
        self.representedID = representedID
        (view as? MaterialCardContainer)?.onClick = onClick
        if let hosting { hosting.rootView = card; return }
        let hosting = NSHostingView(rootView: card)
        BrowsePerformanceTrace.record("card_host_create")
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.hosting = hosting
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        discardPresentation()
    }
    func discardPresentation() {
        (view as? MaterialCardContainer)?.onClick = nil
        hosting?.removeFromSuperview()
        hosting = nil
        representedID = nil
    }
}

/// The card has no inline controls; context menus and accessibility still use
/// the hosting view. Mouse selection uses the original event, without SwiftUI's
/// single/double-tap recognition delay (which can outlive modifier key presses).
@MainActor
private final class MaterialCardContainer: NSView {
    var onClick: ((NSEvent) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        if onClick != nil, target != nil, NSApp.currentEvent?.type == .leftMouseDown { return self }
        return target
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event)
    }
}
