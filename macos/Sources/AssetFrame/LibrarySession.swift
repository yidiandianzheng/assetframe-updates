import AppKit
import SwiftUI

struct LibraryDisplayOptions: Codable, Equatable, Sendable {
    static let minimumThumbnailSize = 100.0
    static let maximumThumbnailSize = 680.0
    static let defaultThumbnailSize = 240.0

    var thumbnailSize: Double = defaultThumbnailSize
    var proportional = true
    var showName = true
    var showSummary = true
    var summary = "尺寸"
    var showExtension = true
    var showExtensionBadge = false
    var showNoteCount = false
    var includeSubfolders = true
    var showSidebar = true
    var showInspector = true

    var imageHeight: Double { min(Self.maximumThumbnailSize, max(Self.minimumThumbnailSize, thumbnailSize)) }
    /// Keep preview cache sizes in a few stable buckets while the slider moves.
    var previewMaximumDimension: Double {
        let requested = min(1_600, max(256, imageHeight * 1.94))
        return (requested / 256).rounded(.up) * 256
    }
    /// Eagle-style gallery policy: cards always use a lightweight thumbnail.
    /// Screen-sized previews are reserved for the focused preview experience.
    var galleryPreviewMaximumDimension: Double { min(512, previewMaximumDimension) }
    var captionHeight: Double { (showName ? 18 : 0) + (showSummary ? 18 : 0) }
    /// Values which alter the contents of a currently visible gallery card.
    /// NativeMaterialGallery reuses visible AppKit items, so these must change
    /// its action context even when the material IDs themselves do not.
    var galleryCardPresentationIdentity: String {
        [
            showName ? "name" : "no-name",
            showSummary ? "summary" : "no-summary",
            summary,
            showExtension ? "extension" : "no-extension",
            showExtensionBadge ? "extension-badge" : "no-extension-badge",
            showNoteCount ? "note-count" : "no-note-count",
            String(Int(galleryPreviewMaximumDimension))
        ].joined(separator: "|")
    }
    func contains(path: String?, folder: String) -> Bool {
        guard let path else { return false }
        let root = URL(fileURLWithPath: folder).standardizedFileURL.path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return includeSubfolders ? url.path.hasPrefix(root == "/" ? root : root + "/") : url.deletingLastPathComponent().path == root
    }
}

struct LibraryScrollAnchor: Codable, Equatable, Sendable {
    var materialID: String
    var offset: Double
    var navigationIdentity: String
    static func filterIdentity(_ filter: MaterialSearchFilter) -> String {
        // Every collection in a search filter is a set. Canonicalize those
        // arrays as well as object keys so an app restart keeps the same scope.
        guard let data = try? JSONEncoder().encode(filter),
              var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return String(describing: filter) }
        for key in Array(value.keys) {
            if let values = value[key] as? [String] { value[key] = values.sorted() }
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let identity = String(data: encoded, encoding: .utf8) else { return String(describing: filter) }
        return identity
    }
}

struct LibraryBrowseState: Codable {
    var scope = "all"
    var search = ""
    var filter = MaterialSearchFilter()
    var selected: Set<String> = []
    var focused: String?
    var scrollY: Double = 0
    var scrollAnchor: LibraryScrollAnchor? = nil
    var table = false
    var display: LibraryDisplayOptions? = nil
    var sortOrder: MaterialSortOrder? = nil
    var regionMarkers: Bool? = false
    var expandedFolderPaths: Set<String>? = nil
}

@MainActor
final class LibrarySession: ObservableObject {
    @Published private(set) var registry = LibraryRegistry()
    @Published private(set) var descriptor: LibraryDescriptor?
    @Published private(set) var store: GlobalMaterialStore?
    @Published private(set) var root: URL?
    @Published private(set) var projectWorkspace: ProjectAutomationService?
    @Published var browse = LibraryBrowseState()
    @Published var error: String?
    @Published var stage = ""
    @Published var showLoading = false
    @Published var busy = false
    @Published var mergeReport: LibraryMergeReport?
    private var mergeSource: URL?
    private var lease: LibraryWriteLease?
    private(set) var switchToken = UUID()
    private var exclusiveMutation = false
    private let registryRoot: URL
    let product: AppProduct
    private let projectEventMonitoring: Bool
    var applicationSupportRoot: URL { registryRoot }
    private let qaRoot: URL?
    private var started = false
    private struct PausedStore {
        var store: GlobalMaterialStore
        var stamp: [String: String]
    }
    private var pausedStores: [String: PausedStore] = [:]
    private var pausedOrder: [String] = []
    private(set) var lastOpenSeconds = 0.0
    private(set) var lastOpenReusedStore = false
    nonisolated private static func storageStamp(_ root: URL) -> [String: String]? {
        var stamp: [String: String] = [:]
        for name in [LibraryDescriptor.filename, "global-material-library.sqlite", "global-material-library.sqlite-wal", "material-import-resume.json"] {
            let url = root.appendingPathComponent(name)
            if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]) {
                stamp[name] = "\(v.fileSize ?? -1)|\(v.contentModificationDate?.timeIntervalSince1970 ?? -1)|\(String(describing: v.fileResourceIdentifier))"
            } else if name == LibraryDescriptor.filename || name == "global-material-library.sqlite" { return nil }
        }
        return stamp
    }
    private final class WeakSession {
        weak var value: LibrarySession?
        init(_ value: LibrarySession) { self.value = value }
    }
    private static var sessions: [WeakSession] = []
    static func finishBeforeTermination() async -> Bool {
        sessions.removeAll { $0.value == nil }
        for session in sessions.compactMap(\.value) {
            session.projectWorkspace?.stop()
            do { if let store = session.store { try await store.pauseSession().get() }; try session.saveBrowse() }
            catch { session.error = error.localizedDescription; return false }
        }; return true
    }
    func retryStart() async { started = false; await start() }
    init(qaRoot: URL?, product: AppProduct = .current, projectEventMonitoring: Bool = true) {
        self.qaRoot = qaRoot
        self.product = product
        self.projectEventMonitoring = projectEventMonitoring
        registryRoot = qaRoot ?? product.applicationSupportRoot
        Self.sessions.removeAll { $0.value == nil }
        Self.sessions.append(WeakSession(self))
    }
    func start() async {
        guard !started else { return }; started = true
        do {
            let readRoot = registryRoot
            registry = try await Task.detached(priority: .userInitiated) { try LibraryRegistry.read(readRoot) }.value
            if let current = registry.locations.first(where: { $0.id == registry.currentID }) {
                await open(URL(fileURLWithPath: current.path)); return
            }
            busy = true; stage = product == .story ? "正在建立项目索引" : "正在备份并迁移旧素材"; showLoading = true
            let oldRoot = registryRoot
            let libraries = registryRoot.appendingPathComponent("Libraries")
            try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
            let initial = libraries.appendingPathComponent(product == .story ? "漫剧项目索引.assetframelibrary" : "素材总库.assetframelibrary")
            if !FileManager.default.fileExists(atPath: initial.path) {
                let snapshot: MaterialSnapshot
                if product == .story { snapshot = MaterialSnapshot(materials: [], links: [], organization: LibraryOrganization()) }
                else { snapshot = try await Task.detached(priority: .userInitiated) { try await LibraryTransfer.backupAndMigrate(root: oldRoot) }.value }
                _ = try await LibraryTransfer.create(at: initial, name: product == .story ? "漫剧项目索引" : "素材总库", snapshot: snapshot)
            }
            busy = false; await open(initial)
        } catch { self.error = error.localizedDescription; busy = false; showLoading = false }
    }
    func open(_ location: URL) async {
        guard !exclusiveMutation else { error = "正在提交资源库操作，请完成后再切换"; return }
        projectWorkspace?.stop()
        let token = UUID(); switchToken = token
        let openStarted = Date(); lastOpenReusedStore = false
        mergeReport = nil; mergeSource = nil
        stage = "正在打开资源库"; busy = true
        let delay = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled && switchToken == token { showLoading = true } }
        defer { delay.cancel(); if switchToken == token { busy = false; showLoading = false; stage = ""; lastOpenSeconds = Date().timeIntervalSince(openStarted) } }
        do {
            let info = try await Task.detached { try LibraryDescriptor.read(location) }.value
            guard switchToken == token else { return }
            if root?.standardizedFileURL == location.standardizedFileURL, let store {
                // Explicit reconnect must read disk even when the old in-memory store looked healthy.
                _ = await store.pauseSession()
                await store.retryLoad().value
                guard switchToken == token else { return }
                if let issue = store.persistenceError { throw MaterialDatabase.error(issue) }
                store.resumeSession(); error = nil; projectWorkspace?.start(); return
            }
            let nextLease = try await Task.detached(priority: .userInitiated) { try LibraryWriteLease(location) }.value
            guard switchToken == token else { return }
            if let old = store {
                try await old.pauseSession().get()
                try saveBrowse()
            }
            guard switchToken == token else { return }
            if let old = store, let oldRoot = root, old.materials.count <= 10_000,
               let stamp = await Task.detached(operation: { Self.storageStamp(oldRoot) }).value {
                guard switchToken == token else { return }
                let key = oldRoot.standardizedFileURL.path
                pausedStores[key] = PausedStore(store: old, stamp: stamp)
                pausedOrder.removeAll { $0 == key }; pausedOrder.append(key)
                while pausedOrder.count > 2 { pausedStores.removeValue(forKey: pausedOrder.removeFirst()) }
            }
            MaterialPlaybackController.shared.stop()
            let managed = qaRoot?.appendingPathComponent("ManagedFiveStar") ?? (product == .story ? registryRoot.appendingPathComponent("ManagedMedia") : URL(fileURLWithPath: "/Volumes/SSD-1TB"))
            let key = location.standardizedFileURL.path
            let stamp = await Task.detached { Self.storageStamp(location) }.value
            guard switchToken == token else { return }
            let cached = pausedStores.removeValue(forKey: key)
            pausedOrder.removeAll { $0 == key }
            let next: GlobalMaterialStore
            if let cached, cached.stamp == stamp, cached.store.persistenceError == nil {
                next = cached.store; lastOpenReusedStore = true
            } else { next = GlobalMaterialStore(rootURL: location, managedRoot: managed, paused: true) }
            await next.waitUntilReady()
            guard switchToken == token else { _ = await next.pauseSession(); return }
            if let issue = next.persistenceError { throw MaterialDatabase.error(issue) }
            let stateURL = registryRoot.appendingPathComponent("browse-\(info.id).json")
            let stateData = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: stateURL) }.value
            guard switchToken == token else { return }
            var updated = registry; updated.record(info, root: location); try updated.save(registryRoot)
            PreviewImagePipeline.shared.cancelPendingAndClearMemory()
            SSDPreviewCache.selectLibrary(info.id)
            next.resumeSession()
            lease = nextLease; store = next; descriptor = info; root = location; registry = updated
            browse = stateData.flatMap { try? JSONDecoder().decode(LibraryBrowseState.self, from: $0) } ?? LibraryBrowseState()
            if browse.scope.hasPrefix("project:") { browse.scope = "all" }
            if product == .story {
                projectWorkspace = ProjectAutomationService(root: location, materials: next, eventMonitoring: projectEventMonitoring)
                projectWorkspace?.start()
            } else { projectWorkspace = nil }
            error = nil
        } catch {
            if switchToken == token { self.error = error.localizedDescription; store?.resumeSession(); projectWorkspace?.start() }
        }
    }
    func saveBrowse() throws {
        guard let descriptor else { return }
        try JSONEncoder().encode(browse).write(to: registryRoot.appendingPathComponent("browse-\(descriptor.id).json"), options: .atomic)
    }
    func chooseOpen() {
        let p = NSOpenPanel(); p.title = "打开 AssetFrame 资源库"; p.canChooseDirectories = true; p.canChooseFiles = false
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await open(url) }
    }
    func chooseCreate() {
        let p = NSSavePanel(); p.title = "创建资源库"; p.nameFieldStringValue = "新资源库.assetframelibrary"
        if FileManager.default.fileExists(atPath: SSDPreviewCache.volume.path) { p.directoryURL = SSDPreviewCache.volume }
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            do {
                _ = try await LibraryTransfer.create(at: url, name: url.deletingPathExtension().lastPathComponent,
                    snapshot: MaterialSnapshot(materials: [], links: [], organization: LibraryOrganization()))
                await open(url)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Inactive and offline entries can be removed without opening their files.
    func removeRegisteredLibrary(_ id: String) async {
        guard !busy, !exclusiveMutation, registry.locations.contains(where: { $0.id == id }) else { return }
        if descriptor?.id == id { await removeCurrentLibrary(); return }
        do {
            var updated = registry
            updated.remove(id)
            if let item = registry.locations.first(where: { $0.id == id }) { pausedStores.removeValue(forKey: item.path); pausedOrder.removeAll { $0 == item.path } }
            if let descriptor { updated.currentID = descriptor.id }
            try updated.save(registryRoot)
            registry = updated
            error = nil
        } catch { self.error = "无法移除资源库登记：" + error.localizedDescription }
    }

    /// Removes only AssetFrame's registry entry. The library directory,
    /// database, linked source files, tags, and notes remain untouched.
    func removeCurrentLibrary() async {
        guard let descriptor, let currentStore = store, !busy, !exclusiveMutation else { return }
        projectWorkspace?.stop()
        exclusiveMutation = true; busy = true; stage = "正在移除项目库登记"
        do {
            try await currentStore.pauseSession().get()
            try saveBrowse()
            var updated = registry
            updated.remove(descriptor.id)
            // An offline entry must not prevent switching to a usable library.
            updated.currentID = updated.locations.first(where: { item in
                (try? LibraryDescriptor.read(URL(fileURLWithPath: item.path)))?.id == item.id
            })?.id
            try updated.save(registryRoot)

            MaterialPlaybackController.shared.stop()
            switchToken = UUID()
            lease = nil
            store = nil
            self.descriptor = nil
            root = nil
            browse = LibraryBrowseState()
            registry = updated
            error = nil
            exclusiveMutation = false; busy = false; stage = ""

            if let next = updated.locations.first(where: { $0.id == updated.currentID }) {
                await open(URL(fileURLWithPath: next.path))
            }
        } catch {
            currentStore.resumeSession()
            self.error = "无法移除项目库：" + error.localizedDescription
            exclusiveMutation = false; busy = false; stage = ""
        }
    }

    func clearCache() async {
        guard let descriptor, let store, !exclusiveMutation else { return }
        exclusiveMutation = true; defer { exclusiveMutation = false }
        do {
            try await store.pauseSession().get()
            try SSDPreviewCache.clearLibrary(descriptor.id)
            PreviewImagePipeline.shared.cancelPendingAndClearMemory()
            self.store = nil
            self.store = store
            store.resumeSession()
        } catch { self.error = error.localizedDescription; store.resumeSession() }
    }
    func chooseMerge() {
        let panel = NSOpenPanel(); panel.title = "选择要合并的 AssetFrame 资源库"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let source = panel.url, source != root, let store else { return }
        let token = switchToken
        Task {
            do {
                let info = try LibraryDescriptor.read(source)
                guard info.id != descriptor?.id else { throw MaterialDatabase.error("不能合并当前资源库自身或其同 ID 副本") }
                let sourceLease = try LibraryWriteLease(source)
                defer { withExtendedLifetime(sourceLease) {} }
                let records = try await Task.detached { try LibraryTransfer.readLibrary(source) }.value
                let current = try await store.committedLibrary()
                let report = try await Task.detached { try LibraryTransfer.merge(source: records, sourceID: info.id, into: current) }.value
                guard switchToken == token else { return }
                mergeReport = report; mergeSource = source
            } catch { self.error = error.localizedDescription }
        }
    }
    func commitMerge() async {
        guard let source = mergeSource, let store, let root, !exclusiveMutation else { return }
        exclusiveMutation = true
        busy = true; defer { exclusiveMutation = false; busy = false; store.resumeSession() }
        do {
            try await store.pauseSession().get()
            let sourceLease = try LibraryWriteLease(source)
            defer { withExtendedLifetime(sourceLease) {} }
            let info = try LibraryDescriptor.read(source)
            let records = try await Task.detached { try LibraryTransfer.readLibrary(source) }.value
            let current = try await store.committedLibrary()
            let revised = try await Task.detached { try LibraryTransfer.merge(source: records, sourceID: info.id, into: current) }.value
            guard let reviewed = mergeReport, revised.added == reviewed.added, revised.conflicts == reviewed.conflicts, revised.groups == reviewed.groups, revised.snapshot.materials == reviewed.snapshot.materials, revised.snapshot.links == reviewed.snapshot.links, revised.snapshot.organization == reviewed.snapshot.organization else {
                mergeReport = revised; throw MaterialDatabase.error("资源库已变化，合并摘要已更新，请重新审阅")
            }
            let backup = root.appendingPathComponent("before-merge-\(UUID().uuidString).sqlite")
            let database = MaterialDatabase(root: root)
            try await database.backup(to: backup)
            let staging = root.appendingPathComponent("Merge-\(UUID().uuidString).assetframelibrary")
            _ = try await LibraryTransfer.create(at: staging, name: "合并校验", snapshot: revised.snapshot)
            try await database.restore(from: staging.appendingPathComponent("global-material-library.sqlite"))
            try await store.replaceLibrary(revised.snapshot)
            mergeReport = nil; mergeSource = nil
        } catch { self.error = error.localizedDescription }
    }
    func deleteTrashedMaterials(_ ids: Set<String>) async {
        guard let store, let root, !busy, !exclusiveMutation else { return }
        exclusiveMutation = true; busy = true
        defer { exclusiveMutation = false; busy = false; store.resumeSession() }
        var moved: [MaterialTrashService.Move] = []
        let journal = root.appendingPathComponent("delete-recovery-" + UUID().uuidString + ".json")
        do {
            try await store.pauseSession().get()
            let before = try await store.committedLibrary()
            let paths = try await Task.detached { try MaterialTrashService.paths(for: ids, in: before) }.value
            // Keep the exact records and intended paths before any filesystem action.
            try JSONEncoder().encode(before).write(to: journal.appendingPathExtension("snapshot"), options: .atomic)
            try JSONEncoder().encode(paths).write(to: journal.appendingPathExtension("paths"), options: .atomic)
            for path in paths {
                let move = try await Task.detached {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                    guard let resulting else { throw MaterialDatabase.error("原文件已送入系统废纸篓，但无法读取恢复位置：\(path)") }
                    return MaterialTrashService.Move(source: path, destination: resulting.path!)
                }.value
                moved.append(move)
                try JSONEncoder().encode(moved).write(to: journal, options: .atomic)
            }
            try await store.replaceLibrary(MaterialTrashService.removing(ids, from: before), expected: before)
            browse.selected.subtract(ids)
            if let id = browse.focused, ids.contains(id) { browse.focused = nil }
            error = nil
        } catch {
            var restoreErrors: [String] = []
            for move in moved.reversed() {
                do { try FileManager.default.moveItem(atPath: move.destination, toPath: move.source) }
                catch { restoreErrors.append(move.source) }
            }
            self.error = "删除未完成：" + error.localizedDescription + (restoreErrors.isEmpty ? "；记录保留，已移动文件已恢复" : "；部分文件仍在系统废纸篓，请按恢复日志找回：" + journal.path)
        }
    }

    func importURLs(_ urls: [URL]) {
        guard let store, !store.isImporting, !busy else { return }
        store.importProjectID = nil
        store.importFiles(urls)
    }

    func chooseImport() {
        let p = NSOpenPanel(); p.title = "导入素材或文件夹"; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        if p.runModal() == .OK { importURLs(p.urls) }
    }
}
