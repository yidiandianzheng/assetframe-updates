import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    static let importedAssetsAvailable = Notification.Name("importedAssetsAvailable")
}

enum ImportPhase: Equatable, Sendable { case scanning, importing, completed }
enum ImportJobKind: Equatable, Sendable { case imageImport, projectScan, pendingStage, confirmImport }

private enum ManagedLibraryCopyTarget: String, Sendable {
    case fiveStar
    case common
}

struct ImportProgressState: Identifiable, Sendable {
    let id: UUID
    var phase: ImportPhase
    var total: Int
    var processed: Int
    var imported: Int
    var skipped: Int
    var currentFilename: String
    var kind: ImportJobKind = .imageImport
    var estimatedRemainingSeconds: TimeInterval? = nil
    var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }
}

struct ExportProgressState: Identifiable, Sendable {
    enum Phase: Equatable, Sendable { case validating, exporting, completed, failed }
    let id: UUID
    var phase: Phase
    var total: Int
    var processed: Int
    var succeeded: Int
    var failed: Int
    var currentFilename: String
    var resultPath: String?
    var message: String
    var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }
}

private struct ImportResult: Sendable { var assets: [AssetItem]; var skipped: Int }
private struct PendingStageResult: Sendable {
    var items: [PendingImportItem]
    var skipped: Int
    var duplicatePaths: [String]
    var duplicateCandidates: [DuplicateImportCandidate]
    var sourceFolderID: String?
    var directoryPaths: [String]
    var total: Int
    var processed: Int
    var wasCancelled: Bool
    var usedFastIndex: Bool
    var failure: String? = nil
}
private struct DuplicateContentReference: Sendable {
    var path: String
    var fileSize: Int64
}
private struct PendingConfirmResult: Sendable { var assets: [AssetItem]; var completedIDs: Set<String>; var failed: Int }
private struct SourceDescriptor: Sendable {
    var url: URL
    var relativePath: String?
    var fileID: String
    var fileSize: Int64
    var createdAt: Date?
    var modifiedAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?

    var pixelCount: Int64 { Int64(pixelWidth ?? 0) * Int64(pixelHeight ?? 0) }
    var sourceVersion: AssetSourceVersion {
        AssetSourceVersion(
            path: url.path, filename: url.lastPathComponent, fileID: fileID, fileSize: fileSize,
            modifiedAt: modifiedAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight, addedAt: Date()
        )
    }
}

private struct GalleryFileMoveRequest: Sendable {
    var galleryID: String
    var sourceURL: URL
}

private struct GalleryFileMoveOutcome: Sendable {
    var galleryID: String
    var result: Result<OriginalFileMoveResult, Error>
}

private struct AssetDerivedState: Sendable {
    var assetIndex: [String: Int]
    var activeAssets: [AssetItem]
    var trashedAssets: [AssetItem]
    var exportAssets: [AssetItem]
    var viewAssets: [SavedView: [AssetItem]]
    var viewCounts: [SavedView: Int]
    var tagCounts: [String: Int]
    var total: Int
    var approved: Int
    var pending: Int
    var redo: Int
    var missing: Int
}

private struct PreparedProjectSnapshot: Sendable {
    var snapshot: ProjectSnapshot
    var derived: AssetDerivedState
    var normalizedLegacyLocations: Bool
}

private enum PendingAIClassificationOutcome: Sendable {
    case success(PendingAIAnalysisSuggestion)
    case failure(itemID: String, message: String)
}

@MainActor
final class AssetStore: ObservableObject {
    @Published var assets: [AssetItem] = [] { didSet { invalidateFolderQueries() } }
    // 仅用于无损读取和回写旧版数据库；无限画布功能已移除。
    private var groups: [AssetGroup] = []
    private var relations: [AssetRelation] = []
    @Published var projects: [ProjectRecord] = []
    @Published var currentProject: ProjectRecord
    @Published var exportNames: [String: String] = [:]
    @Published var pendingImports: [PendingImportItem] = [] { didSet { pendingGalleryCache = nil; markContentChanged() } }
    private var pendingGalleryCache: [AssetItem]?
    private var importedGalleryAssets: [AssetItem] {
        if let pendingGalleryCache { return pendingGalleryCache }
        let result = pendingImports.map { $0.makePreviewAsset(checkSourceAvailability: false) }
        pendingGalleryCache = result
        return result
    }
    @Published private(set) var localFolders: [LocalFolderSource] = [] { didSet { invalidateFolderQueries(clearPaths: true) } }
    @Published var assetStacks: [AssetVariantRecord] = []
    @Published var assetEntities: [AssetEntityRecord] = []
    @Published private(set) var generationBatches: [GenerationBatchRecord] = []
    @Published var viewCounts: [SavedView: Int] = [:]
    @Published private(set) var tagCounts: [String: Int] = [:]
    @Published var toast: String?
    @Published var isImporting = false
    @Published var isProjectScanning = false
    @Published var isLoadingProject = true
    @Published private(set) var projectLoadProgress: ProjectLoadProgress?
    @Published private(set) var projectLoadErrorMessage: String?
    @Published private(set) var showsProjectLoadOverlay = false
    let importProgressController = ImportProgressController()
    var importProgress: ImportProgressState? {
        get { importProgressController.state }
        set { importProgressController.replace(with: newValue) }
    }
    @Published var pendingVisionClassificationProgress: PendingVisionClassificationProgressState?
    @Published var pendingAIClassificationProgress: PendingAIClassificationProgressState?
    @Published var exportProgress: ExportProgressState?
    @Published var exportValidationMessage: String?
    @Published var assetActionMessage: String?
    @Published private(set) var duplicateImportMessage: String?
    @Published private(set) var duplicateImportPaths: [String] = []
    @Published private(set) var duplicateImportCandidates: [DuplicateImportCandidate] = []
    @Published var undoTrashAssetID: String?
    @Published var feishuImportPreview: FeishuImportPreview?
    @Published var projectDeletionMessage: String?
    @Published var libraryAuditSession: LibraryAuditSession?
    @Published private(set) var contentRevision: UInt64 = 0
    /// 当旧资产记录缺少原目录路径时，用原文件 ID（唯一文件名作后备）恢复目录归属。
    private var localFolderFileIndex: [String: [String: String]] = [:] { didSet { invalidateFolderQueries() } }
    private var scriptExtractions: [ScriptExtractionRecord] = []

    private struct FolderQueryEntry {
        var projectID: String
        var sourceID: String
        var path: String
        var scope: LocalFolderScope
        var search: String
        var filter: AssetFilter
        var sort: AssetSortConfiguration
        var result: [AssetItem]
    }
    private var folderQueries: [FolderQueryEntry] = []
    private var childFolderQueries: [String: [GalleryChildFolder]] = [:]
    private var resolvedFolderPaths: [String: (id: String, relativePath: String)] = [:]
    private var normalizedFolderRoots: [(id: String, root: String)]?
    private var unresolvedFolderPaths: Set<String> = []

    private func invalidateFolderQueries(clearPaths: Bool = false) {
        folderQueries.removeAll(keepingCapacity: true)
        childFolderQueries.removeAll(keepingCapacity: true)
        if clearPaths {
            normalizedFolderRoots = nil
            resolvedFolderPaths.removeAll(keepingCapacity: true)
            unresolvedFolderPaths.removeAll(keepingCapacity: true)
        }
    }

    @Published private(set) var resumableImport: ImportResumeRecord?
    private var metadataSupplementTask: Task<Void, Never>?
    private func resumeURL(for project: ProjectRecord) -> URL {
        Self.pendingManifestSupportRoot(project: project).appendingPathComponent("image-import-resume.json")
    }
    func resumeImageImport() {
        guard let job = resumableImport, job.projectID == currentProject.id else { return }
        stageImages(job.paths.map(URL.init(fileURLWithPath:)), localFolder: job.localFolder)
    }
    func cancelBackgroundMetadata() { metadataSupplementTask?.cancel() }
    func waitForBackgroundMetadata() async { await metadataSupplementTask?.value }
    private func supplementPendingMetadata() {
        metadataSupplementTask?.cancel()
        let project = currentProject
        let candidates = pendingImports.filter { $0.technicalMetadataChecked != true }
        let formalSources = assets.filter { $0.deletedAt == nil }.map { ($0.sourceOriginalPath ?? $0.imagePath, $0.sourceFileSize ?? 0) }
        metadataSupplementTask = Task { [weak self] in
            guard let self else { return }
            let timing = ImportTiming()
            defer { timing.report("project_background") }
            for start in stride(from: 0, to: candidates.count, by: 32) {
                guard !Task.isCancelled, !isImporting, currentProject.id == project.id else { return }
                let chunk = Array(candidates[start..<min(start + 32, candidates.count)])
                let worker = Task.detached(priority: .utility) {
                    var values: [PendingImportItem] = []
                    var hashes: [String: String] = [:]
                    var formalHashes: [String: String] = [:]
                    let sizes = Set(chunk.map(\.sourceFileSize))
                    for (path, size) in formalSources where sizes.contains(size) {
                        guard !Task.isCancelled else { break }
                        let url = URL(fileURLWithPath: path)
                        if ImportResumeRecord.availableLocally(url), let hash = Self.fileSHA256(atPath: path, cache: &hashes) {
                            formalHashes[hash] = path
                        }
                    }
                    for var item in chunk {
                        guard !Task.isCancelled else { break }
                        let url = URL(fileURLWithPath: item.originalSourcePath)
                        guard ImportResumeRecord.availableLocally(url) else { continue }
                        let before = Self.describe(url: url, root: url.deletingLastPathComponent(), includeDimensions: false)
                        guard before.fileSize == item.sourceFileSize, before.modifiedAt == item.sourceModifiedAt else { continue }
                        SSDPreviewCache.warmThumbnail(path: url.path, size: item.sourceFileSize, modified: item.sourceModifiedAt)
                        let dimensions = Self.imageDimensions(at: url)
                        let hash = Self.fileSHA256(atPath: url.path, cache: &hashes)
                        let after = Self.describe(url: URL(fileURLWithPath: url.path), root: url.deletingLastPathComponent(), includeDimensions: false)
                        guard before.fileSize == after.fileSize, before.modifiedAt == after.modifiedAt, hash != nil else { continue }
                        item.pixelWidth = dimensions.width
                        item.pixelHeight = dimensions.height
                        item.contentFingerprint = hash
                        item.technicalMetadataChecked = true
                        values.append(item)
                    }
                    return (values, formalHashes)
                }
                let (updates, formalHashes) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, !isImporting, currentProject.id == project.id else { return }
                var revised = pendingImports
                var hashes = formalHashes
                for item in revised { if let hash = item.contentFingerprint { hashes[hash] = item.originalSourcePath } }
                for item in updates {
                    guard let i = revised.firstIndex(where: { $0.id == item.id }),
                          revised[i].sourceIdentity == item.sourceIdentity,
                          revised[i].originalSourcePath == item.originalSourcePath else { continue }
                    revised[i].pixelWidth = item.pixelWidth
                    revised[i].pixelHeight = item.pixelHeight
                    revised[i].contentFingerprint = item.contentFingerprint
                    revised[i].technicalMetadataChecked = true
                    if let hash = item.contentFingerprint {
                        if let existing = hashes[hash], existing != item.originalSourcePath {
                            let candidate = DuplicateImportCandidate(existingPath: existing, incomingItem: revised[i])
                            if !duplicateImportCandidates.contains(where: { $0.queueIdentity == candidate.queueIdentity }) {
                                duplicateImportCandidates.append(candidate)
                            }
                        } else { hashes[hash] = item.originalSourcePath }
                    }
                }
                pendingImports = revised
                markContentChanged()
                await persistPendingManifest(pendingImports, project: project)
                duplicateImportPaths = Array(Set(duplicateImportCandidates.flatMap { [$0.existingPath, $0.incomingPath] })).sorted()
                updateDuplicateImportMessage()
                persistDuplicateImportQueueSoon()
            }
        }
    }

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let legacyAssetsURL: URL
    private let legacyDataURL: URL
    private let registry: ProjectRegistry
    private var database: ProjectDatabase
    private let pendingSourceTrashService: any PendingSourceTrashing
    private let managedLibrarySSDURL: URL
    private let pendingManifestWriter = PendingImportManifestWriter()
    private let pendingImportJournalWriter = PendingImportJournalWriter()
    private let duplicateImportQueueWriter = DuplicateImportQueueWriter()
    private var pendingManifestRevision: UInt64 = 0
    private var pendingManifestSaveTask: Task<Void, Never>?
    private var duplicateImportQueueRevision: UInt64 = 0
    private var duplicateImportQueueSaveTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var sourceRefreshTask: Task<Void, Never>?
    private var codexInboxWatchTask: Task<Void, Never>?
    private var importDismissTask: Task<Void, Never>?
    private var pendingVisionClassificationTask: Task<Void, Never>?
    private var pendingAIClassificationTask: Task<Void, Never>?
    private var projectLoadOverlayTask: Task<Void, Never>?
    private var projectLoadToken = UUID()
    private var hasPendingChanges = false
    private var saveGeneration: UInt64 = 0
    private var snapshotCache: [String: ProjectSnapshot] = [:]
    private var snapshotCacheOrder: [String] = []
    private var assetIndex: [String: Int] = [:]
    private var activeSecurityURL: URL?
    private var cachedCounts = (total: 0, approved: 0, pending: 0, redo: 0, missing: 0)
    private var cachedActiveAssets: [AssetItem] = []
    private var cachedTrashedAssets: [AssetItem] = []
    private var cachedExportAssets: [AssetItem] = []
    private var cachedViewAssets: [SavedView: [AssetItem]] = [:]
    private var cachedSearchView = ""
    private var cachedSearchQuery = ""
    private var cachedSearchFilter = AssetFilter()
    private var cachedSearchSort = AssetSortConfiguration()
    private var cachedSearchRevision: UInt64 = .max
    private var cachedSearchAssets: [AssetItem] = []
    private var lastImportProgressUpdate = Date.distantPast
    private var importProgressEstimator = ImportProgressEstimator()
    private var imageImportTask: Task<Void, Never>?
    private var pendingPublication: [PendingImportItem] = []
    private var publishedImportIDs: Set<String> = []
    private var lastImportPublication = Date.distantPast
    private var lastExportProgressUpdate = Date.distantPast
    private var managedCopyingKeys: Set<String> = []

    init(
        rootURL customRootURL: URL? = nil,
        pendingSourceTrashService: any PendingSourceTrashing = SystemPendingSourceTrashService(),
        managedLibrarySSDURL customManagedLibrarySSDURL: URL? = nil
    ) {
        self.pendingSourceTrashService = pendingSourceTrashService
        managedLibrarySSDURL = (customManagedLibrarySSDURL
            ?? URL(fileURLWithPath: "/Volumes/SSD-1TB", isDirectory: true)).standardizedFileURL
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = customRootURL ?? support.appendingPathComponent("AssetFrame", isDirectory: true)
        legacyAssetsURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
        legacyDataURL = rootURL.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: legacyAssetsURL, withIntermediateDirectories: true)
        registry = ProjectRegistry(rootURL: rootURL, legacyAssetsURL: legacyAssetsURL)
        currentProject = registry.current
        projects = registry.projects
        database = ProjectDatabase(url: URL(fileURLWithPath: registry.current.databasePath))
        Task { await loadProject(registry.current, migrateLegacy: true) }
    }

    var counts: (total: Int, approved: Int, pending: Int, redo: Int, missing: Int) { cachedCounts }
    var activeAssets: [AssetItem] { cachedActiveAssets }
    var trashedAssets: [AssetItem] { cachedTrashedAssets }
    var exportAssets: [AssetItem] { cachedExportAssets }
    var currentProjectRootURL: URL { registry.resolvedRootURL(for: currentProject) }
    var displayedProjectName: String { projectLoadProgress?.projectName ?? currentProject.name }
    var pendingImportDirectoryURL: URL {
        Self.pendingManifestSupportRoot(project: currentProject)
            .appendingPathComponent(Self.pendingManifestSupportDirectoryName, isDirectory: true)
    }
    var codexInboxDirectoryURL: URL { currentProjectRootURL.appendingPathComponent(CodexGenerationIntake.inboxDirectoryName, isDirectory: true) }
    var availableTags: [String] { tagCounts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var aiSuggestionAdoptionSummary: AISuggestionAdoptionSummary {
        pendingImports.reduce(into: AISuggestionAdoptionSummary(pending: 0, acceptedWithoutChanges: 0, acceptedAfterEditing: 0, ignored: 0)) { result, item in
            guard let suggestion = item.aiVisionSuggestion else { return }
            switch suggestion.effectiveDecision {
            case .pending: result.pending += 1
            case .ignored: result.ignored += 1
            case .applied:
                if suggestion.wasEditedByUser == true { result.acceptedAfterEditing += 1 }
                else { result.acceptedWithoutChanges += 1 }
            }
        }
    }

    func assets(for view: SavedView, search: String) -> [AssetItem] {
        assets(for: view, search: search, filter: AssetFilter(), sort: AssetSortConfiguration(.newest))
    }

    func assets(for view: SavedView, search: String, filter: AssetFilter, sort: AssetSortConfiguration) -> [AssetItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedSearchView == view.rawValue,
           cachedSearchQuery == query,
           cachedSearchFilter == filter,
           cachedSearchSort == sort,
           cachedSearchRevision == contentRevision {
            return cachedSearchAssets
        }
        let source = (cachedViewAssets[view] ?? []) + importedGalleryAssets.filter { view.includes($0) }
        let result = AssetQuery.apply(to: source, search: query, filter: filter, sort: sort)
        cachedSearchView = view.rawValue
        cachedSearchQuery = query
        cachedSearchFilter = filter
        cachedSearchSort = sort
        cachedSearchRevision = contentRevision
        cachedSearchAssets = result
        return result
    }

    func asset(withID id: String) -> AssetItem? {
        guard let index = assetIndex[id], assets.indices.contains(index) else { return nil }
        return assets[index]
    }

    func markAssetUsed(_ id: String, at date: Date = .now) {
        updateAsset(id) { $0.lastUsedAt = date }
    }

    @MainActor
    func prepareLibraryAudit(assetIDs: [String], scopeDescription: String) {
        let scope = Set(assetIDs)
        let issues = LibraryAuditAnalyzer.analyze(assets: assets, variants: assetStacks, scopeAssetIDs: scope)
        libraryAuditSession = LibraryAuditSession(
            id: UUID(), projectID: currentProject.id, scopeDescription: scopeDescription,
            issues: issues, suggestions: [], appliedSuggestionIDs: [], phase: .localReady,
            message: "本地检查完成"
        )
    }

    @MainActor
    func applyLibraryAuditSuggestion(_ suggestionID: String) {
        guard var session = libraryAuditSession,
              let suggestion = session.suggestions.first(where: { $0.id == suggestionID }),
              let assetID = suggestion.assetID,
              let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        if let name = suggestion.proposedName, !name.isEmpty { assets[index].name = name }
        if let type = suggestion.assetType { assets[index].type = type }
        if !suggestion.tags.isEmpty { assets[index].tags = suggestion.tags }
        if let summary = suggestion.summary { assets[index].assetDescription = summary }
        session.appliedSuggestionIDs.insert(suggestionID)
        libraryAuditSession = session
        rebuildDerivedState()
        scheduleSave()
    }

    func loadProject(_ project: ProjectRecord, migrateLegacy: Bool = false, requestToken: UUID? = nil) async {
        let token = requestToken ?? UUID()
        if projectLoadToken != token || projectLoadProgress?.projectID != project.id || !isLoadingProject {
            beginProjectLoad(project, token: token)
        }
        guard projectLoadToken == token else { return }
        updateProjectLoad(stage: .loadingDatabase, project: project, token: token)
        metadataSupplementTask?.cancel()
        resumableImport = nil
        // Detached work from a previous project must never keep the next one
        // visually stuck in an import state.
        isImporting = false
        isProjectScanning = false
        importProgress = nil
        duplicateImportMessage = nil
        duplicateImportPaths = []
        duplicateImportCandidates = []
        saveTask?.cancel()
        saveTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        codexInboxWatchTask?.cancel()
        codexInboxWatchTask = nil
        importDismissTask?.cancel()
        pendingVisionClassificationTask?.cancel()
        pendingVisionClassificationTask = nil
        pendingVisionClassificationProgress = nil
        pendingAIClassificationTask?.cancel()
        pendingAIClassificationTask = nil
        pendingAIClassificationProgress = nil
        let root = registry.resolvedRootURL(for: project)
        _ = root.startAccessingSecurityScopedResource()
        let nextDatabase = ProjectDatabase(url: URL(fileURLWithPath: project.databasePath))
        if !migrateLegacy, let cached = snapshotCache[project.id] {
            guard projectLoadToken == token else {
                root.stopAccessingSecurityScopedResource()
                return
            }
            updateProjectLoad(stage: .buildingIndex, project: project, token: token)
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepareProjectSnapshot(cached)
            }.value
            guard projectLoadToken == token else {
                root.stopAccessingSecurityScopedResource()
                return
            }
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = root
            currentProject = project
            database = nextDatabase
            projects = registry.projects
            updateProjectLoad(stage: .renderingFirstScreen, project: project, token: token)
            install(prepared: prepared, project: project, token: token)
            return
        }
        do {
            if try await nextDatabase.isEmpty() {
                let legacyURL = legacyDataURL
                let enrichedLegacy: LibraryData? = if migrateLegacy, project.isLegacy {
                    await Task.detached(priority: .userInitiated) {
                        guard let legacy = Self.loadLegacyJSON(at: legacyURL) else { return nil }
                        return Self.enrichLegacy(legacy, project: project, root: root)
                    }.value
                } else { nil }
                if let enriched = enrichedLegacy {
                    try await nextDatabase.replace(with: ProjectSnapshot(library: enriched, exportNames: [:]))
                    backupLegacyJSON()
                }
            }
            let snapshot = try await nextDatabase.load { [weak self] databaseProgress in
                Task { @MainActor [weak self] in
                    guard let self, self.projectLoadToken == token,
                          self.projectLoadProgress?.stage == .loadingDatabase else { return }
                    let completed = max(self.projectLoadProgress?.completed ?? 0, databaseProgress.completed)
                    self.projectLoadProgress = ProjectLoadProgress(
                        projectID: project.id,
                        projectName: project.name,
                        stage: .loadingDatabase,
                        completed: completed,
                        total: databaseProgress.total,
                        startedAt: self.projectLoadProgress?.startedAt ?? .now
                    )
                }
            }
            guard projectLoadToken == token else {
                root.stopAccessingSecurityScopedResource()
                return
            }
            updateProjectLoad(stage: .buildingIndex, project: project, token: token)
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepareProjectSnapshot(snapshot)
            }.value
            guard projectLoadToken == token else {
                root.stopAccessingSecurityScopedResource()
                return
            }
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = root
            currentProject = project
            database = nextDatabase
            projects = registry.projects
            pendingImports = []
            localFolderFileIndex = [:]
            updateProjectLoad(stage: .renderingFirstScreen, project: project, token: token)
            install(prepared: prepared, project: project, token: token)
        } catch {
            guard projectLoadToken == token else { return }
            root.stopAccessingSecurityScopedResource()
            isLoadingProject = false
            projectLoadOverlayTask?.cancel()
            projectLoadErrorMessage = error.localizedDescription
            showsProjectLoadOverlay = true
            updateProjectLoad(stage: .failed, project: project, token: token)
        }
    }

    private func beginProjectLoad(_ project: ProjectRecord, token: UUID) {
        projectLoadToken = token
        projectLoadOverlayTask?.cancel()
        isLoadingProject = true
        showsProjectLoadOverlay = false
        projectLoadErrorMessage = nil
        projectLoadProgress = ProjectLoadProgress(
            projectID: project.id, projectName: project.name, stage: .preparing,
            completed: 0, total: nil, startedAt: .now
        )
        projectLoadOverlayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self,
                  self.projectLoadToken == token, self.isLoadingProject else { return }
            self.showsProjectLoadOverlay = true
        }
    }

    private func updateProjectLoad(stage: ProjectLoadStage, project: ProjectRecord, token: UUID) {
        guard projectLoadToken == token else { return }
        let previous = projectLoadProgress
        projectLoadProgress = ProjectLoadProgress(
            projectID: project.id, projectName: project.name, stage: stage,
            completed: previous?.completed ?? 0, total: previous?.total,
            startedAt: previous?.startedAt ?? .now
        )
    }

    private func install(prepared: PreparedProjectSnapshot, project: ProjectRecord, token: UUID) {
        guard projectLoadToken == token else { return }
        let snapshot = prepared.snapshot
        assets = snapshot.library.assets
        groups = snapshot.library.groups
        relations = snapshot.library.relations
        assetStacks = snapshot.library.assetStacks ?? []
        scriptExtractions = snapshot.library.scriptExtractions ?? []
        generationBatches = snapshot.library.generationBatches ?? []
        localFolders = snapshot.localFolders
        exportNames = snapshot.exportNames
        hasPendingChanges = false
        applyDerivedState(prepared.derived)
        cache(snapshot: currentSnapshot, projectID: project.id)
        isLoadingProject = false
        projectLoadOverlayTask?.cancel()
        projectLoadOverlayTask = nil
        projectLoadErrorMessage = nil
        updateProjectLoad(stage: .ready, project: project, token: token)
        showsProjectLoadOverlay = false
        if prepared.normalizedLegacyLocations { scheduleSave() }
        syncManagedAssetsIntoLibrary()
        // Like Obsidian indexing: show cached metadata first. Restore the small
        // pending-import manifest before a background scan so files are not
        // staged twice after a project switch.
        let root = registry.resolvedRootURL(for: project)
        Task { [weak self] in
            guard let self else { return }
            let restored = await Task.detached(priority: .utility) {
                (
                    pending: Self.loadPendingManifest(project: project, legacyRoot: root),
                    duplicates: Self.loadDuplicateImportQueue(project: project)
                )
            }.value
            guard self.projectLoadToken == token, self.currentProject.id == project.id else { return }
            // `isLoadingProject` is cleared after the SQLite snapshot is installed so the
            // window can render immediately. A user action may therefore stage items while
            // the small manifest is still loading. Merge the restored snapshot instead of
            // replacing live state, otherwise a fast first import or AI suggestion can vanish.
            let liveIDs = Set(self.pendingImports.map(\.id))
            let liveIdentities = Set(self.pendingImports.map(\.sourceIdentity))
            self.pendingImports.append(contentsOf: restored.pending.filter {
                !liveIDs.contains($0.id) && !liveIdentities.contains($0.sourceIdentity)
            })
            let liveDuplicateIdentities = Set(self.duplicateImportCandidates.map(\.queueIdentity))
            self.duplicateImportCandidates.append(contentsOf: restored.duplicates.filter {
                !liveDuplicateIdentities.contains($0.queueIdentity)
            })
            self.duplicateImportPaths = Array(Set(
                self.duplicateImportPaths + self.duplicateImportCandidates.flatMap {
                    [$0.existingPath, $0.incomingPath]
                }
            )).sorted()
            self.updateDuplicateImportMessage()
            self.markContentChanged()
            let resumeURL = self.resumeURL(for: project)
            let resume = await Task.detached { ImportResumeRecord.load(from: resumeURL) }.value
            guard self.projectLoadToken == token else { return }
            self.resumableImport = resume
            self.supplementPendingMetadata()
            if !self.isImporting {
                if await self.persistPendingManifest(self.pendingImports, project: project) {
                    await self.pendingImportJournalWriter.clear(Self.pendingImportJournalURL(project: project))
                }
            }
            if !project.isLegacy, !project.isInitialLibraryPlaceholder {
                self.ensureProjectRootFolder(project: project, root: root, token: token)
                self.ensureLinkedExternalFolderSources(project: project, root: root, token: token)
            }
            // Opening an empty project must never recursively scan a broad
            // workspace on its own. Scanning is now always an explicit action.
            self.refreshSourceAvailability()
            self.startCodexInboxWatcher(project: project, root: root, token: token)
        }
    }

    func switchProject(_ id: String) {
        guard !isImporting else { showToast("图片处理完成后再切换项目"); return }
        guard let project = projects.first(where: { $0.id == id }) else { return }
        if id == currentProject.id {
            guard isLoadingProject else { return }
            projectLoadToken = UUID()
            registry.select(currentProject.id)
            projects = registry.projects
            projectLoadOverlayTask?.cancel()
            projectLoadOverlayTask = nil
            isLoadingProject = false
            showsProjectLoadOverlay = false
            projectLoadErrorMessage = nil
            projectLoadProgress = ProjectLoadProgress(
                projectID: currentProject.id, projectName: currentProject.name, stage: .ready,
                completed: assets.count, total: assets.count, startedAt: .now
            )
            return
        }
        cache(snapshot: currentSnapshot, projectID: currentProject.id)
        let token = UUID()
        beginProjectLoad(project, token: token)
        Task {
            await flushCurrentProject()
            guard projectLoadToken == token else { return }
            registry.select(id)
            await loadProject(project, requestToken: token)
        }
    }

    func retryProjectLoad() {
        guard let progress = projectLoadProgress,
              let project = projects.first(where: { $0.id == progress.projectID }) else { return }
        Task { await loadProject(project) }
    }

    func revealCurrentProjectData() {
        let project = projectLoadProgress.flatMap { progress in
            projects.first(where: { $0.id == progress.projectID })
        } ?? currentProject
        let databaseURL = URL(fileURLWithPath: project.databasePath)
        let target = fileManager.fileExists(atPath: databaseURL.path)
            ? databaseURL
            : databaseURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    @discardableResult
    func renameCurrentProject(to displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showToast("项目名称不能为空")
            return false
        }
        guard !projects.contains(where: {
            $0.id != currentProject.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            showToast("已经存在同名项目")
            return false
        }
        guard let renamed = registry.rename(currentProject.id, to: name) else {
            showToast("项目重命名失败")
            return false
        }
        currentProject = renamed
        projects = registry.projects
        showToast("项目显示名称已改为“\(name)”；文件夹名称和路径保持不变")
        return true
    }

    /// 只移除 AssetFrame 的项目登记；不删除项目目录、原图或项目 SQLite 数据库。
    func removeProject(_ id: String) {
        guard !isImporting, projects.count > 1 else { return }
        Task {
            if id == currentProject.id { await flushCurrentProject() }
            guard let next = registry.remove(id) else { return }
            projects = registry.projects
            if id == currentProject.id { await loadProject(next) }
            else { showToast("已移除项目登记") }
        }
    }

    func chooseProjectFolder() {
        guard !isImporting else { showToast("图片处理完成后再打开项目"); return }
        let panel = NSOpenPanel()
        panel.title = "选择项目素材文件夹"
        panel.prompt = "打开项目"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        cache(snapshot: currentSnapshot, projectID: currentProject.id)
        let project = registry.addProject(folderURL: folder)
        projects = registry.projects
        let token = UUID()
        beginProjectLoad(project, token: token)
        Task {
            await flushCurrentProject()
            guard projectLoadToken == token else { return }
            await loadProject(project, requestToken: token)
        }
    }

    func relocateCurrentProject() {
        guard !isImporting else { showToast("图片处理完成后再重新定位"); return }
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(currentProject.name)”"
        panel.prompt = "重新定位"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url,
              let project = registry.relocate(currentProject.id, to: folder) else { return }
        currentProject = project; projects = registry.projects; scanCurrentProject()
    }

    func revealCurrentProject() { NSWorkspace.shared.activateFileViewerSelecting([currentProjectRootURL]) }

    func copyCurrentProjectPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentProjectRootURL.path, forType: .string)
        showToast("已复制项目本地路径")
    }

    func scanCurrentProject() {
        guard !isImporting else { return }
        if currentProject.isLegacy {
            refreshSourceAvailability()
            showToast("已检查旧资料库的原图状态；未建档图片不会自动加入")
            return
        }
        scanCurrentFolderForNewImages()
    }

    func scanCurrentFolderForNewImages() {
        stageImages([currentProjectRootURL], kind: .projectScan)
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "导入本地文件夹"
        panel.prompt = "导入并建立目录树"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLocalFolder(url)
    }

    func refreshLocalFolder(_ id: String) {
        invalidateFolderQueries(clearPaths: true)
        guard let folder = localFolders.first(where: { $0.id == id }),
              let url = resolvedURL(for: folder) else { return }
        stageImages([url], kind: .projectScan, localFolder: folder)
    }

    func revealLocalFolder(_ id: String, relativePath: String = "") {
        guard let folder = localFolders.first(where: { $0.id == id }),
              let root = resolvedURL(for: folder) else { return }
        let target = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else {
            showToast("本地目录已移动或磁盘未连接")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func copyLocalFolderPath(_ id: String, relativePath: String = "") {
        guard let folder = localFolders.first(where: { $0.id == id }) else { return }
        let root = URL(fileURLWithPath: folder.rootPath)
        let path = relativePath.isEmpty ? root.path : root.appendingPathComponent(relativePath, isDirectory: true).path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showToast("已复制本地路径")
    }

    @discardableResult
    func renameLocalFolder(_ id: String, relativePath: String, to proposedName: String) -> String? {
        guard !relativePath.isEmpty,
              let name = Self.validRenameComponent(proposedName),
              let index = localFolders.firstIndex(where: { $0.id == id }),
              let root = resolvedURL(for: localFolders[index]) else {
            assetActionMessage = "请输入有效的文件夹名称；名称不能包含 / 或 :。"
            return nil
        }
        let oldURL = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard oldURL.path != newURL.path else { return relativePath }
        guard fileManager.fileExists(atPath: oldURL.path) else {
            assetActionMessage = "原文件夹已移动或磁盘未连接。"
            return nil
        }
        guard !fileManager.fileExists(atPath: newURL.path) else {
            assetActionMessage = "同级目录中已经存在“\(name)”。"
            return nil
        }
        let accessStarted = root.startAccessingSecurityScopedResource()
        defer { if accessStarted { root.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.moveItem(at: oldURL, to: newURL)
        } catch {
            assetActionMessage = "文件夹重命名失败：\(error.localizedDescription)"
            return nil
        }

        let oldRelativePath = relativePath
        let parent = relativePath.split(separator: "/").dropLast().joined(separator: "/")
        let newRelativePath = parent.isEmpty ? name : "\(parent)/\(name)"
        localFolders[index].directoryPaths = localFolders[index].directoryPaths.map {
            Self.replacingRelativePrefix($0, oldPrefix: oldRelativePath, newPrefix: newRelativePath)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        updateIndexedPaths(
            oldAbsolutePrefix: oldURL.path,
            newAbsolutePrefix: newURL.path,
            sourceFolderID: id,
            oldRelativePrefix: oldRelativePath,
            newRelativePrefix: newRelativePath
        )
        rebuildDerivedState()
        scheduleSave()
        persistPendingManifestSoon()
        markContentChanged()
        showToast("已重命名文件夹为“\(name)”")
        return newRelativePath
    }

    nonisolated private static func validRenameComponent(_ proposedName: String) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else { return nil }
        return name
    }

    nonisolated private static func replacingRelativePrefix(
        _ value: String,
        oldPrefix: String,
        newPrefix: String
    ) -> String {
        if value == oldPrefix { return newPrefix }
        let prefix = oldPrefix + "/"
        guard value.hasPrefix(prefix) else { return value }
        return newPrefix + "/" + value.dropFirst(prefix.count)
    }

    private func updateIndexedPaths(
        oldAbsolutePrefix: String,
        newAbsolutePrefix: String,
        sourceFolderID: String,
        oldRelativePrefix: String,
        newRelativePrefix: String
    ) {
        func replacingAbsolutePrefix(_ value: String?) -> String? {
            guard let value else { return nil }
            if value == oldAbsolutePrefix { return newAbsolutePrefix }
            let prefix = oldAbsolutePrefix + "/"
            guard value.hasPrefix(prefix) else { return value }
            return newAbsolutePrefix + "/" + value.dropFirst(prefix.count)
        }

        for index in assets.indices {
            assets[index].imagePath = replacingAbsolutePrefix(assets[index].imagePath) ?? assets[index].imagePath
            assets[index].sourceOriginalPath = replacingAbsolutePrefix(assets[index].sourceOriginalPath)
            assets[index].importSourcePath = replacingAbsolutePrefix(assets[index].importSourcePath)
            if assets[index].sourceFolderID == sourceFolderID,
               let relative = assets[index].sourceRelativePath {
                assets[index].sourceRelativePath = Self.replacingRelativePrefix(
                    relative,
                    oldPrefix: oldRelativePrefix,
                    newPrefix: newRelativePrefix
                )
            }
            if var versions = assets[index].sourceVersions {
                for versionIndex in versions.indices {
                    guard let updatedPath = replacingAbsolutePrefix(versions[versionIndex].path) else { continue }
                    versions[versionIndex].path = updatedPath
                    versions[versionIndex].filename = URL(fileURLWithPath: updatedPath).lastPathComponent
                }
                assets[index].sourceVersions = versions
            }
            assets[index].thumbnailKey = nil
        }
        for index in pendingImports.indices {
            pendingImports[index].stagedPath = replacingAbsolutePrefix(pendingImports[index].stagedPath)
                ?? pendingImports[index].stagedPath
            pendingImports[index].originalSourcePath = replacingAbsolutePrefix(pendingImports[index].originalSourcePath)
                ?? pendingImports[index].originalSourcePath
            if pendingImports[index].sourceFolderID == sourceFolderID,
               let relative = pendingImports[index].sourceRelativePath {
                pendingImports[index].sourceRelativePath = Self.replacingRelativePrefix(
                    relative,
                    oldPrefix: oldRelativePrefix,
                    newPrefix: newRelativePrefix
                )
            }
        }
        if var index = localFolderFileIndex[sourceFolderID] {
            for key in index.keys {
                if let relative = index[key] {
                    index[key] = Self.replacingRelativePrefix(
                        relative,
                        oldPrefix: oldRelativePrefix,
                        newPrefix: newRelativePrefix
                    )
                }
            }
            localFolderFileIndex[sourceFolderID] = index
        }
        duplicateImportPaths = duplicateImportPaths.map {
            replacingAbsolutePrefix($0) ?? $0
        }
    }

    /// Dragging a gallery item onto the local-folder tree is an explicit
    /// physical move. The database is updated only after FileManager confirms
    /// the source file reached the destination.
    func moveGalleryAssets(
        _ galleryIDs: [String],
        fromProjectID projectID: String,
        toLocalFolder folderID: String,
        relativePath: String
    ) {
        guard projectID == currentProject.id else {
            showToast("只能整理当前项目中的图片")
            return
        }
        guard let folder = localFolders.first(where: { $0.id == folderID }),
              let root = resolvedURL(for: folder) else {
            showToast("目标文件夹已失联，请先重新定位")
            return
        }
        let destinationDirectory = relativePath.isEmpty
            ? root.standardizedFileURL
            : root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard destinationDirectory.path == rootPath || destinationDirectory.path.hasPrefix(rootPath + "/") else {
            showToast("目标文件夹无效")
            return
        }

        var seen = Set<String>()
        let requests = galleryIDs.filter { seen.insert($0).inserted }.compactMap { galleryID -> GalleryFileMoveRequest? in
            if galleryID.hasPrefix("PENDING-") {
                let pendingID = String(galleryID.dropFirst("PENDING-".count))
                guard let item = pendingImport(withID: pendingID) else { return nil }
                let original = URL(fileURLWithPath: item.originalSourcePath).standardizedFileURL
                let staged = URL(fileURLWithPath: item.stagedPath).standardizedFileURL
                let source = fileManager.fileExists(atPath: original.path) ? original : staged
                return GalleryFileMoveRequest(galleryID: galleryID, sourceURL: source)
            }
            guard let asset = asset(withID: galleryID) else { return nil }
            let current = URL(fileURLWithPath: asset.imagePath).standardizedFileURL
            if let originalPath = asset.sourceOriginalPath, !originalPath.isEmpty {
                let original = URL(fileURLWithPath: originalPath).standardizedFileURL
                if fileManager.fileExists(atPath: original.path) {
                    return GalleryFileMoveRequest(galleryID: galleryID, sourceURL: original)
                }
            }
            return GalleryFileMoveRequest(galleryID: galleryID, sourceURL: current)
        }
        guard !requests.isEmpty else {
            showToast("没有可移动的原文件")
            return
        }

        let activeAccess = root.startAccessingSecurityScopedResource()
        let targetRoot = root.standardizedFileURL
        let currentProjectID = currentProject.id
        Task { [weak self] in
            defer { if activeAccess { root.stopAccessingSecurityScopedResource() } }
            let outcomes = await Task.detached(priority: .userInitiated) {
                requests.map { request in
                    do {
                        let moved = try OriginalFileMoveService.move(
                            sourceURL: request.sourceURL,
                            destinationDirectory: destinationDirectory
                        )
                        return GalleryFileMoveOutcome(galleryID: request.galleryID, result: .success(moved))
                    } catch {
                        return GalleryFileMoveOutcome(galleryID: request.galleryID, result: .failure(error))
                    }
                }
            }.value
            guard let self, self.currentProject.id == currentProjectID else { return }
            self.applyGalleryFileMoveOutcomes(
                outcomes,
                targetFolderID: folderID,
                targetRoot: targetRoot
            )
        }
    }

    private func applyGalleryFileMoveOutcomes(
        _ outcomes: [GalleryFileMoveOutcome],
        targetFolderID: String,
        targetRoot: URL
    ) {
        var movedCount = 0
        var unchangedCount = 0
        var renamedCount = 0
        var failures: [String] = []
        var pendingChanged = false

        for outcome in outcomes {
            switch outcome.result {
            case let .failure(error):
                failures.append(error.localizedDescription)
            case let .success(move):
                if move.sourceURL == move.destinationURL {
                    unchangedCount += 1
                    continue
                }
                let relative = Self.relativePath(of: move.destinationURL, root: targetRoot)
                let descriptor = Self.describe(url: move.destinationURL, root: currentProjectRootURL)
                if outcome.galleryID.hasPrefix("PENDING-") {
                    let pendingID = String(outcome.galleryID.dropFirst("PENDING-".count))
                    guard let index = pendingImports.firstIndex(where: { $0.id == pendingID }) else { continue }
                    pendingImports[index].stagedPath = move.destinationURL.path
                    pendingImports[index].originalSourcePath = move.destinationURL.path
                    pendingImports[index].originalFilename = move.destinationURL.lastPathComponent
                    pendingImports[index].sourceFolderID = targetFolderID
                    pendingImports[index].sourceRelativePath = relative
                    pendingImports[index].sourceFileID = descriptor.fileID
                    pendingImports[index].sourceFileSize = descriptor.fileSize
                    pendingImports[index].sourceCreatedAt = descriptor.createdAt
                    pendingImports[index].sourceModifiedAt = descriptor.modifiedAt
                    pendingImports[index].pixelWidth = descriptor.pixelWidth
                    pendingImports[index].pixelHeight = descriptor.pixelHeight
                    pendingChanged = true
                } else if let index = assetIndex[outcome.galleryID] {
                    let currentPath = URL(fileURLWithPath: assets[index].imagePath).standardizedFileURL.path
                    if currentPath == move.sourceURL.path {
                        apply(descriptor: descriptor, to: &assets[index], archiveCurrent: false)
                    } else {
                        assets[index].sourceFileID = descriptor.fileID
                        assets[index].sourceFileSize = descriptor.fileSize
                        assets[index].sourceCreatedAt = descriptor.createdAt
                        assets[index].sourceModifiedAt = descriptor.modifiedAt
                    }
                    assets[index].sourceOriginalPath = move.destinationURL.path
                    assets[index].sourceFolderID = targetFolderID
                    assets[index].sourceRelativePath = relative
                    assets[index].isSourceMissing = false
                }
                movedCount += 1
                if move.wasRenamed { renamedCount += 1 }
            }
        }

        if movedCount > 0 {
            rebuildDerivedState()
            scheduleSave()
            if pendingChanged { persistPendingManifestSoon() }
        }
        if let index = localFolders.firstIndex(where: { $0.id == targetFolderID }) {
            localFolders[index].lastScannedAt = .now
        }

        var message = movedCount > 0 ? "已移动 (movedCount) 个原文件" : "没有文件需要移动"
        if renamedCount > 0 { message += "，其中 (renamedCount) 个因同名自动改名" }
        if unchangedCount > 0 { message += "，(unchangedCount) 个已在目标目录" }
        if !failures.isEmpty {
            message += "，(failures.count) 个失败"
            assetActionMessage = "部分原文件移动失败：\(failures.prefix(2).joined(separator: "；"))"
        }
        showToast(message)
    }

    func relocateLocalFolder(_ id: String) {
        guard let index = localFolders.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(localFolders[index].name)”"
        panel.prompt = "使用此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localFolders[index].name = url.lastPathComponent
        localFolders[index].rootPath = url.standardizedFileURL.path
        localFolders[index].bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        scheduleSave()
        refreshLocalFolder(id)
    }

    func removeLocalFolder(_ id: String) {
        localFolders.removeAll { $0.id == id }
        scheduleSave()
        showToast("已移除文件夹索引，本地原图未受影响")
    }

    func assets(
        inLocalFolder id: String,
        relativePath: String,
        scope: LocalFolderScope = .recursive,
        search: String,
        filter: AssetFilter,
        sort: AssetSortConfiguration
    ) -> [AssetItem] {
        if let cached = folderQueries.first(where: {
            $0.projectID == currentProject.id && $0.sourceID == id && $0.path == relativePath
                && $0.scope == scope && $0.search == search && $0.filter == filter && $0.sort == sort
        }) { return cached.result }
        guard let folder = localFolders.first(where: { $0.id == id }) else { return [] }
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let isProjectRoot = Self.sameFolder(folder.rootPath, currentProjectRootURL.path)
        let confirmed = cachedActiveAssets.filter { asset in
            Self.asset(
                asset,
                belongsToLocalFolder: id,
                rootPath: folder.rootPath,
                relativePath: relativePath,
                prefix: prefix,
                scope: scope,
                includesAllAtRoot: isProjectRoot && localFolders.count == 1,
                resolvedLocation: preferredLocalFolderLocation(
                    for: asset.sourceOriginalPath ?? asset.importSourcePath ?? asset.imagePath
                ),
                indexedRelativePath: indexedRelativePath(for: asset, sourceID: id)
            )
        }
        let awaitingConfirmation = pendingImports
            .filter {
                Self.pendingImport(
                    $0,
                    belongsToLocalFolder: id,
                    rootPath: folder.rootPath,
                    relativePath: relativePath,
                    prefix: prefix,
                    scope: scope,
                    includesAllAtRoot: isProjectRoot && localFolders.count == 1,
                    resolvedLocation: preferredLocalFolderLocation(for: $0.originalSourcePath)
                )
            }
            .map { $0.makePreviewAsset(checkSourceAvailability: false) }
        let result = AssetQuery.apply(
            to: confirmed + awaitingConfirmation,
            search: search,
            filter: filter,
            sort: sort
        )
        if folderQueries.count >= 32 { folderQueries.removeFirst() }
        folderQueries.append(FolderQueryEntry(projectID: currentProject.id, sourceID: id,
            path: relativePath, scope: scope, search: search, filter: filter, sort: sort, result: result))
        return result
    }

    func assetsInAllLocalFolders(
        search: String,
        filter: AssetFilter,
        sort: AssetSortConfiguration
    ) -> [AssetItem] {
        var seenIDs = Set<String>()
        var combined: [AssetItem] = []
        for folder in localFolders {
            let folderAssets = assets(
                inLocalFolder: folder.id,
                relativePath: "",
                search: "",
                filter: AssetFilter(),
                sort: .newest
            )
            for asset in folderAssets where seenIDs.insert(asset.id).inserted {
                combined.append(asset)
            }
        }
        return AssetQuery.apply(to: combined, search: search, filter: filter, sort: sort)
    }

    var allLocalFolderAssetCount: Int {
        assetsInAllLocalFolders(
            search: "",
            filter: AssetFilter(),
            sort: .newest
        ).count
    }

    func localFolderAssetCount(_ id: String, relativePath: String) -> Int {
        guard let folder = localFolders.first(where: { $0.id == id }) else { return 0 }
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let isProjectRoot = Self.sameFolder(folder.rootPath, currentProjectRootURL.path)
        let confirmedCount = cachedActiveAssets.count {
            Self.asset(
                $0,
                belongsToLocalFolder: id,
                rootPath: folder.rootPath,
                relativePath: relativePath,
                prefix: prefix,
                scope: .recursive,
                includesAllAtRoot: isProjectRoot && localFolders.count == 1,
                resolvedLocation: preferredLocalFolderLocation(
                    for: $0.sourceOriginalPath ?? $0.importSourcePath ?? $0.imagePath
                ),
                indexedRelativePath: indexedRelativePath(for: $0, sourceID: id)
            )
        }
        let pendingCount = pendingImports.count {
            Self.pendingImport(
                $0,
                belongsToLocalFolder: id,
                rootPath: folder.rootPath,
                relativePath: relativePath,
                prefix: prefix,
                scope: .recursive,
                includesAllAtRoot: isProjectRoot && localFolders.count == 1,
                resolvedLocation: preferredLocalFolderLocation(for: $0.originalSourcePath)
            )
        }
        return confirmedCount + pendingCount
    }

    func galleryChildFolders(sourceID: String, parentPath: String) -> [GalleryChildFolder] {
        let key = "\(currentProject.id)|\(sourceID)|\(parentPath)"
        if let cached = childFolderQueries[key] { return cached }
        guard let folder = localFolders.first(where: { $0.id == sourceID }) else { return [] }
        let result = GalleryChildFolderResolver.directChildren(
            directoryPaths: folder.directoryPaths,
            parentPath: parentPath
        ).map { relativePath in
            let directAssets = assets(
                inLocalFolder: sourceID,
                relativePath: relativePath,
                scope: .currentOnly,
                search: "",
                filter: AssetFilter(),
                sort: .newest
            )
            let childFolderCount = GalleryChildFolderResolver.directChildren(
                directoryPaths: folder.directoryPaths,
                parentPath: relativePath
            ).count
            let coverAsset = directAssets.first ?? assets(
                inLocalFolder: sourceID,
                relativePath: relativePath,
                scope: .recursive,
                search: "",
                filter: AssetFilter(),
                sort: .newest
            ).first
            return GalleryChildFolder(
                sourceID: sourceID,
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                directFileCount: directAssets.count,
                childFolderCount: childFolderCount,
                coverAsset: coverAsset
            )
        }
        if childFolderQueries.count >= 32 { childFolderQueries.removeAll(keepingCapacity: true) }
        childFolderQueries[key] = result
        return result
    }

    nonisolated private static func asset(
        _ asset: AssetItem,
        belongsToLocalFolder id: String,
        rootPath: String,
        relativePath: String,
        prefix: String,
        scope: LocalFolderScope,
        includesAllAtRoot: Bool,
        resolvedLocation: (id: String, relativePath: String)?,
        indexedRelativePath: String?
    ) -> Bool {
        if relativePath.isEmpty, includesAllAtRoot, scope == .recursive { return true }
        let filePath: String
        if let resolvedLocation {
            guard resolvedLocation.id == id else { return false }
            filePath = resolvedLocation.relativePath
        } else if asset.sourceFolderID == id {
            filePath = asset.sourceRelativePath ?? ""
        } else if let relative = relativeFilePath(asset.sourceOriginalPath, inside: rootPath) {
            filePath = relative
        } else if let indexedRelativePath {
            filePath = indexedRelativePath
        } else {
            return false
        }
        let rawDirectory = (filePath as NSString).deletingLastPathComponent
        let directory = rawDirectory == "." ? "" : rawDirectory
        return scope.includes(directory: directory, selectedDirectory: relativePath)
    }

    nonisolated private static func pendingImport(
        _ item: PendingImportItem,
        belongsToLocalFolder id: String,
        rootPath: String,
        relativePath: String,
        prefix: String,
        scope: LocalFolderScope,
        includesAllAtRoot: Bool,
        resolvedLocation: (id: String, relativePath: String)?
    ) -> Bool {
        if relativePath.isEmpty, includesAllAtRoot, scope == .recursive { return true }
        let filePath: String
        if let resolvedLocation {
            guard resolvedLocation.id == id else { return false }
            filePath = resolvedLocation.relativePath
        } else if item.sourceFolderID == id {
            filePath = item.sourceRelativePath ?? ""
        } else if let relative = relativeFilePath(item.originalSourcePath, inside: rootPath) {
            filePath = relative
        } else {
            return false
        }
        let rawDirectory = (filePath as NSString).deletingLastPathComponent
        let directory = rawDirectory == "." ? "" : rawDirectory
        return scope.includes(directory: directory, selectedDirectory: relativePath)
    }

    nonisolated private static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    nonisolated private static func relativeFilePath(_ path: String?, inside rootPath: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        return String(candidate.dropFirst(prefix.count))
    }

    private func preferredLocalFolderLocation(for path: String?) -> (id: String, relativePath: String)? {
        guard let path else { return nil }
        if resolvedFolderPaths.count + unresolvedFolderPaths.count > 20_000 {
            resolvedFolderPaths.removeAll(keepingCapacity: true)
            unresolvedFolderPaths.removeAll(keepingCapacity: true)
        }
        if let cached = resolvedFolderPaths[path] { return cached }
        if unresolvedFolderPaths.contains(path) { return nil }
        if normalizedFolderRoots == nil {
            normalizedFolderRoots = localFolders.map { ($0.id, URL(fileURLWithPath: $0.rootPath).standardizedFileURL.resolvingSymlinksInPath().path) }
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let result = normalizedFolderRoots?.compactMap { folder -> (id: String, relativePath: String, rootLength: Int)? in
            let prefix = folder.root + "/"
            guard candidate.hasPrefix(prefix) else { return nil }
            return (folder.id, String(candidate.dropFirst(prefix.count)), folder.root.count)
        }.max { $0.rootLength < $1.rootLength }.map { (id: $0.id, relativePath: $0.relativePath) }
        if let result { resolvedFolderPaths[path] = result }
        else { unresolvedFolderPaths.insert(path) }
        return result
    }

    private func indexedRelativePath(for asset: AssetItem, sourceID: String) -> String? {
        guard let index = localFolderFileIndex[sourceID] else { return nil }
        if let originalID = asset.importSourceFileID, !originalID.isEmpty,
           let relative = index["id:\(originalID)"] {
            return relative
        }
        return index["name:\(asset.originalFilename.localizedLowercase)"]
    }

    private func ensureProjectRootFolder(project: ProjectRecord, root: URL, token: UUID) {
        let rootPath = root.standardizedFileURL.path
        let sourceID: String
        if let existing = localFolders.first(where: { Self.sameFolder($0.rootPath, rootPath) }) {
            sourceID = existing.id
        } else {
            let source = LocalFolderSource(
                id: "PROJECT-\(project.id)",
                name: project.name,
                rootPath: rootPath,
                bookmarkData: project.bookmarkData,
                directoryPaths: [""],
                createdAt: .now,
                lastScannedAt: nil
            )
            localFolders.insert(source, at: 0)
            sourceID = source.id
            scheduleSave()
        }
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                let paths = Self.localDirectoryPaths(at: root, excludingManagedDirectoriesUnder: root)
                let descriptors = Self.scanFolder(root, excludingManagedDirectoriesUnder: root)
                var index: [String: String] = [:]
                let byFilename = Dictionary(grouping: descriptors, by: { $0.url.lastPathComponent.localizedLowercase })
                for descriptor in descriptors {
                    guard let relative = Self.relativePath(of: descriptor.url, root: root) else { continue }
                    if !descriptor.fileID.isEmpty {
                        index["id:\(descriptor.fileID)"] = relative
                    }
                    let filename = descriptor.url.lastPathComponent.localizedLowercase
                    if byFilename[filename]?.count == 1 {
                        index["name:\(filename)"] = relative
                    }
                }
                return (paths, index)
            }.value
            guard let self,
                  self.projectLoadToken == token,
                  self.currentProject.id == project.id,
                  let index = self.localFolders.firstIndex(where: { $0.id == sourceID }) else { return }
            self.localFolders[index].name = project.name
            self.localFolders[index].rootPath = rootPath
            self.localFolders[index].directoryPaths = scan.0
            self.localFolders[index].lastScannedAt = .now
            self.localFolderFileIndex[sourceID] = scan.1
            self.scheduleSave()
        }
    }

    nonisolated static func externalLinkedProjectRoots(
        at projectRoot: URL,
        projectName: String,
        externalVolumePrefix: String = "/Volumes/"
    ) -> [URL] {
        let fileManager = FileManager.default
        let children = (try? fileManager.contentsOfDirectory(
            at: projectRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var rootsByPath: [String: URL] = [:]
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: child.path) else { continue }
            let destination = rawDestination.hasPrefix("/")
                ? URL(fileURLWithPath: rawDestination, isDirectory: true)
                : child.deletingLastPathComponent().appendingPathComponent(rawDestination, isDirectory: true)
            let parent = destination.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let parentPath = parent.standardizedFileURL.path
            guard parent.lastPathComponent == projectName,
                  parentPath.hasPrefix(externalVolumePrefix) else { continue }
            rootsByPath[parentPath] = parent
        }
        return rootsByPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func ensureLinkedExternalFolderSources(project: ProjectRecord, root: URL, token: UUID) {
        Task { [weak self] in
            let scans = await Task.detached(priority: .utility) {
                Self.externalLinkedProjectRoots(at: root, projectName: project.name).map { linkedRoot in
                    let paths = Self.localDirectoryPaths(at: linkedRoot, excludingManagedDirectoriesUnder: root)
                    let descriptors = Self.scanFolder(linkedRoot, excludingManagedDirectoriesUnder: root)
                    var fileIndex: [String: String] = [:]
                    let byFilename = Dictionary(grouping: descriptors, by: { $0.url.lastPathComponent.localizedLowercase })
                    for descriptor in descriptors {
                        guard let relative = Self.relativePath(of: descriptor.url, root: linkedRoot) else { continue }
                        if !descriptor.fileID.isEmpty { fileIndex["id:\(descriptor.fileID)"] = relative }
                        let filename = descriptor.url.lastPathComponent.localizedLowercase
                        if byFilename[filename]?.count == 1 { fileIndex["name:\(filename)"] = relative }
                    }
                    return (root: linkedRoot, paths: paths, fileIndex: fileIndex)
                }
            }.value
            guard let self,
                  self.projectLoadToken == token,
                  self.currentProject.id == project.id else { return }
            var changed = false
            for scan in scans {
                let linkedPath = scan.root.standardizedFileURL.path
                let sourceID: String
                if let index = self.localFolders.firstIndex(where: { Self.sameFolder($0.rootPath, linkedPath) }) {
                    sourceID = self.localFolders[index].id
                    self.localFolders[index].name = project.name
                    self.localFolders[index].directoryPaths = scan.paths
                    self.localFolders[index].lastScannedAt = .now
                } else {
                    let source = LocalFolderSource(
                        id: UUID().uuidString,
                        name: project.name,
                        rootPath: linkedPath,
                        bookmarkData: nil,
                        directoryPaths: scan.paths,
                        createdAt: .now,
                        lastScannedAt: .now
                    )
                    self.localFolders.append(source)
                    sourceID = source.id
                }
                self.localFolderFileIndex[sourceID] = scan.fileIndex
                changed = true
            }
            if changed {
                self.rebuildDerivedState()
                self.scheduleSave()
                self.markContentChanged()
            }
        }
    }

    func importLocalFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = localFolders.first(where: { URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path == path }) {
            refreshLocalFolder(existing.id)
            return
        }
        let folder = LocalFolderSource(
            id: UUID().uuidString,
            name: url.lastPathComponent,
            rootPath: path,
            bookmarkData: try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
            directoryPaths: [""],
            createdAt: .now,
            lastScannedAt: nil
        )
        localFolders.append(folder)
        scheduleSave()
        stageImages([url], localFolder: folder)
    }

    private func resolvedURL(for folder: LocalFolderSource) -> URL? {
        if let bookmarkData = folder.bookmarkData {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return resolved
            }
        }
        return URL(fileURLWithPath: folder.rootPath)
    }

    func relinkSource(for id: String) {
        guard let index = assetIndex[id] else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(assets[index].name)”的原图"
        panel.prompt = "使用此图片"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let root = currentProjectRootURL
            let descriptor = await Task.detached(priority: .userInitiated) { Self.describe(url: url, root: root) }.value
            guard let currentIndex = assetIndex[id] else { return }
            apply(descriptor: descriptor, to: &assets[currentIndex], archiveCurrent: false)
            rebuildDerivedState(); scheduleSave(); showToast("原图已重新定位·\(assets[currentIndex].resolutionLabel)")
        }
    }

    func requestRenameOriginalFile(for id: String) {
        guard let asset = asset(withID: id) else { return }
        let original = asset.sourceOriginalPath.flatMap { path in
            fileManager.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let source = original ?? URL(fileURLWithPath: asset.imagePath)
        guard fileManager.fileExists(atPath: source.path) else {
            assetActionMessage = "原文件已移动或磁盘未连接。"
            return
        }
        guard let name = promptForRename(
            title: "重命名原文件",
            message: "将直接修改 Finder 中的真实文件名；扩展名 .\(source.pathExtension) 保持不变。",
            currentName: source.deletingPathExtension().lastPathComponent
        ) else { return }
        _ = renameOriginalFile(for: id, toBaseName: name)
    }

    @discardableResult
    func renameOriginalFile(for id: String, toBaseName proposedName: String) -> String? {
        guard let asset = asset(withID: id) else { return nil }
        let originalPath = asset.sourceOriginalPath.flatMap {
            fileManager.fileExists(atPath: $0) ? $0 : nil
        }
        return renameOriginalFile(atPath: originalPath ?? asset.imagePath, toBaseName: proposedName)
    }

    @discardableResult
    func renamePendingOriginalFile(_ id: String, toBaseName proposedName: String) -> String? {
        guard let item = pendingImport(withID: id) else { return nil }
        return renameOriginalFile(atPath: item.originalSourcePath, toBaseName: proposedName)
    }

    @discardableResult
    private func renameOriginalFile(atPath path: String, toBaseName proposedName: String) -> String? {
        guard let baseName = Self.validRenameComponent(proposedName) else {
            assetActionMessage = "请输入有效的文件名；名称不能包含 / 或 :。"
            return nil
        }
        let oldURL = URL(fileURLWithPath: path).standardizedFileURL
        guard fileManager.fileExists(atPath: oldURL.path) else {
            assetActionMessage = "原文件已移动或磁盘未连接。"
            return nil
        }
        let fileExtension = oldURL.pathExtension
        let filename = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(filename).standardizedFileURL
        guard oldURL.path != newURL.path else { return oldURL.path }
        guard !fileManager.fileExists(atPath: newURL.path) else {
            assetActionMessage = "同一文件夹中已经存在“\(filename)”。"
            return nil
        }
        let scopeRoot = localFolders.compactMap(resolvedURL(for:)).first {
            oldURL.path == $0.path || oldURL.path.hasPrefix($0.path + "/")
        } ?? currentProjectRootURL
        let accessStarted = scopeRoot.startAccessingSecurityScopedResource()
        defer { if accessStarted { scopeRoot.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.moveItem(at: oldURL, to: newURL)
        } catch {
            assetActionMessage = "原文件重命名失败：\(error.localizedDescription)"
            return nil
        }

        updateIndexedFilePath(from: oldURL.path, to: newURL.path)
        rebuildDerivedState()
        scheduleSave()
        persistPendingManifestSoon()
        markContentChanged()
        showToast("原文件已重命名为“\(filename)”")
        return newURL.path
    }

    func fileLocation(for id: String) -> AssetFileLocation? {
        guard let asset = assets.first(where: { $0.id == id }) else { return nil }
        return AssetFileLocationResolver.location(for: asset)
    }

    func originalSourcePath(for id: String) -> String? {
        guard let asset = asset(withID: id),
              let path = asset.sourceOriginalPath,
              !path.isEmpty,
              URL(fileURLWithPath: path).standardizedFileURL.path != URL(fileURLWithPath: asset.imagePath).standardizedFileURL.path else {
            return nil
        }
        return path
    }

    func revealOriginalSource(for id: String) {
        guard let path = originalSourcePath(for: id), fileManager.fileExists(atPath: path) else {
            showToast("本地来源已移动或磁盘未连接")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyOriginalSourcePath(for id: String) {
        guard let path = originalSourcePath(for: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showToast("已复制原始本地路径")
    }

    @discardableResult
    func revealFileLocation(for id: String) -> Bool {
        guard let location = fileLocation(for: id) else {
            showToast("未记录文件位置")
            return false
        }
        guard location.exists else {
            showToast("文件已失联，请先重新定位")
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([location.url])
        markAssetUsed(id)
        return true
    }

    @discardableResult
    func copyFileLocation(for id: String) -> Bool {
        guard let location = fileLocation(for: id) else {
            showToast("未记录文件位置")
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(location.path, forType: .string)
        markAssetUsed(id)
        showToast("已复制文件路径")
        return true
    }

    @discardableResult
    func copyOriginalImage(for id: String) -> Bool {
        guard let location = fileLocation(for: id), location.exists else {
            showToast("原图文件已移动或磁盘未连接")
            return false
        }
        return copyOriginalImage(at: location.url, assetID: id)
    }

    @discardableResult
    func copyOriginalImage(at url: URL, assetID: String? = nil) -> Bool {
        do {
            try OriginalImageClipboard.copyImage(at: url)
            if let assetID { markAssetUsed(assetID) }
            showToast("已复制原图，可直接到 Codex 粘贴")
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    func chooseHigherResolutionReplacement(for id: String) {
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "为“\(asset.name)”选择更高清版本"
        panel.prompt = "替换为高清版"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await replaceSource(for: id, with: url, requireHigherResolution: true) }
    }

    @discardableResult
    func replaceSource(for id: String, with url: URL, requireHigherResolution: Bool = true) async -> Bool {
        guard let index = assetIndex[id] else { return false }
        let root = currentProjectRootURL
        let descriptor = await Task.detached(priority: .userInitiated) { Self.describe(url: url, root: root) }.value
        guard let width = descriptor.pixelWidth, let height = descriptor.pixelHeight, width > 0, height > 0 else {
            assetActionMessage = "无法读取所选图片的像素尺寸，请换一张有效的 PNG、JPG、WebP、HEIC 或 TIFF。"
            return false
        }
        let old = assets[index]
        let currentPixels = Int64(old.pixelWidth ?? 0) * Int64(old.pixelHeight ?? 0)
        if requireHigherResolution, currentPixels > 0, descriptor.pixelCount <= currentPixels {
            assetActionMessage = "新图为 \(width) × \(height)（\(ResolutionLabel.label(width: width, height: height))），没有高于当前 \(old.dimensionText)（\(old.resolutionLabel)）。原图未替换。"
            return false
        }
        apply(descriptor: descriptor, to: &assets[index], archiveCurrent: true)
        rebuildDerivedState(); scheduleSave()
        showToast("已替换为 \(assets[index].resolutionLabel) 高清原图，旧版本仍保留")
        return true
    }

    private func apply(descriptor: SourceDescriptor, to asset: inout AssetItem, archiveCurrent: Bool) {
        if archiveCurrent, !asset.imagePath.isEmpty, asset.imagePath != descriptor.url.path {
            var history = asset.sourceVersions ?? []
            let previous = asset.currentSourceVersion
            if !history.contains(where: { $0.path == previous.path && $0.modifiedAt == previous.modifiedAt }) { history.append(previous) }
            asset.sourceVersions = history
        }
        asset.imagePath = descriptor.url.path
        asset.originalFilename = descriptor.url.lastPathComponent
        asset.sourceRelativePath = descriptor.relativePath
        asset.sourceFileID = descriptor.fileID
        asset.sourceFileSize = descriptor.fileSize
        asset.sourceCreatedAt = descriptor.createdAt
        asset.sourceModifiedAt = descriptor.modifiedAt
        asset.pixelWidth = descriptor.pixelWidth
        asset.pixelHeight = descriptor.pixelHeight
        asset.isSourceMissing = false
        asset.thumbnailKey = nil
        if archiveCurrent { asset.sourceReplacedAt = Date() }
    }

    private func refreshSourceAvailability() {
        sourceRefreshTask?.cancel()
        let projectID = currentProject.id
        let current = assets
        let startingRevision = contentRevision
        sourceRefreshTask = Task(priority: .background) { [weak self] in
            // Let visible thumbnails win the first disk reads after a project opens.
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled, let self else { return }
            let refreshed = await Self.refreshSourceMetadata(current)
            guard !Task.isCancelled else { return }
            // A user edit can happen while file metadata is read in the background.
            // Never replace that newer state with the snapshot captured before the edit.
            guard currentProject.id == projectID,
                  contentRevision == startingRevision,
                  assets.map(\.id) == refreshed.map(\.id) else { return }
            if refreshed != assets {
                assets = refreshed
                rebuildDerivedState()
                scheduleSave()
            }
            sourceRefreshTask = nil
        }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "选择要建立索引的图片"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        stageImages(panel.urls)
    }

    /// 只取消项目在 AssetFrame 中的登记；用户项目文件及项目记忆库均保留。
    func removeCurrentProjectKeepingMemory() {
        removeCurrentProject(deleteMemory: false)
    }

    /// 删除 AssetFrame 为此项目维护的记忆库，并移入系统废纸篓；绝不删除用户项目根目录或根目录中其他文件。
    func removeCurrentProjectAndMemory() {
        removeCurrentProject(deleteMemory: true)
    }

    private func removeCurrentProject(deleteMemory: Bool) {
        guard projects.count > 1 else {
            projectDeletionMessage = "至少保留一个项目。请先添加或打开另一个项目文件夹，再删除当前项目。"
            return
        }
        let project = currentProject
        if deleteMemory {
            let projectRoot = currentProjectRootURL.standardizedFileURL
            let databaseDirectory = URL(fileURLWithPath: project.databasePath).deletingLastPathComponent().standardizedFileURL
            let targets = [
                projectRoot.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true),
                projectRoot.appendingPathComponent(Self.libraryDirectoryName, isDirectory: true),
                databaseDirectory
            ]
            do {
                for target in targets where fileManager.fileExists(atPath: target.path) {
                    try fileManager.trashItem(at: target, resultingItemURL: nil)
                }
            } catch {
                projectDeletionMessage = "项目记忆库未能完整移入废纸篓，已取消删除项目：\(error.localizedDescription)"
                return
            }
        }
        guard let next = registry.remove(project.id) else {
            projectDeletionMessage = "无法删除当前项目。"
            return
        }
        saveTask?.cancel(); sourceRefreshTask?.cancel(); importDismissTask?.cancel(); pendingManifestSaveTask?.cancel()
        duplicateImportQueueSaveTask?.cancel()
        snapshotCache.removeValue(forKey: project.id)
        snapshotCacheOrder.removeAll { $0 == project.id }
        projects = registry.projects
        Task { await loadProject(next) }
    }

    func stageImages(
        _ urls: [URL],
        kind: ImportJobKind = .pendingStage,
        localFolder: LocalFolderSource? = nil
    ) {
        guard !isImporting else { showToast("正在处理图片，请稍候"); return }
        guard !urls.isEmpty else { return }
        importDismissTask?.cancel()
        metadataSupplementTask?.cancel()
        pendingPublication = []
        publishedImportIDs = []
        lastImportPublication = .distantPast
        let project = currentProject
        let projectID = project.id
        let root = currentProjectRootURL
        let knownIdentities = Set(
            pendingImports.map(\.sourceIdentity)
                + duplicateImportCandidates.map { $0.incomingItem.sourceIdentity }
                + assets.map(Self.importIdentity)
        )
        let knownContentReferences = pendingImports.map {
            DuplicateContentReference(path: $0.stagedPath, fileSize: $0.sourceFileSize)
        } + assets.compactMap { asset in
            guard let fileSize = asset.sourceFileSize, fileSize > 0 else { return nil }
            return DuplicateContentReference(path: asset.sourceOriginalPath ?? asset.imagePath, fileSize: fileSize)
        }
        let jobID = UUID()
        let securityURL = localFolder.flatMap { _ in urls.first }
        let securityAccessStarted = securityURL?.startAccessingSecurityScopedResource() ?? false
        isImporting = true
        isProjectScanning = kind == .projectScan
        importProgress = ImportProgressState(
            id: jobID, phase: .scanning, total: 0, processed: 0, imported: 0, skipped: 0,
            currentFilename: kind == .projectScan ? "正在扫描项目文件夹…" : "正在扫描所选文件…", kind: kind
        )
        let timing = ImportTiming()
        let relay = ImportProgressRelay<ImportProgressState> { [weak self] progress in
            await self?.applyImportProgress(progress)
        }
        imageImportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                timing.report("project")
                if securityAccessStarted { securityURL?.stopAccessingSecurityScopedResource() }
            }
            let job = ImportResumeRecord(id: jobID, paths: urls.map(\.path), projectID: project.id, localFolder: localFolder)
            let resumeURL = resumeURL(for: project)
            do { try await Task.detached { try job.save(to: resumeURL) }.value; resumableImport = job }
            catch { assetActionMessage = "无法保存恢复任务：\(error.localizedDescription)"; isImporting = false; return }
            guard currentProject.id == projectID, importProgress?.id == jobID else { return }
            let worker = Task.detached(priority: .userInitiated) {
                await Self.prepareStaging(
                    urls: urls, projectRoot: root,
                    knownIdentities: knownIdentities, jobID: jobID, kind: kind,
                    localFolder: localFolder, knownContentReferences: knownContentReferences, timing: timing
                ) { progress in
                    relay.submit(progress)
                } checkpoint: { batch in
                    try await self.persistImportCheckpoint(
                        batch,
                        jobID: jobID,
                        project: project, timing: timing
                    )
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard currentProject.id == projectID, importProgress?.id == jobID else { return }
            let liveIdentities = Set(pendingImports.map(\.sourceIdentity))
            pendingImports.append(contentsOf: result.items.filter {
                !liveIdentities.contains($0.sourceIdentity) && !self.publishedImportIDs.contains($0.id)
            })
            pendingPublication = []
            if let sourceFolderID = result.sourceFolderID,
               let index = localFolders.firstIndex(where: { $0.id == sourceFolderID }) {
                localFolders[index].directoryPaths = result.directoryPaths
                localFolders[index].lastScannedAt = .now
                scheduleSave()
            }
            let saved = await persistPendingManifest(pendingImports, project: project)
            if saved { await pendingImportJournalWriter.clear(Self.pendingImportJournalURL(project: project)) }
            if let failure = result.failure { assetActionMessage = failure }
            if !saved { assetActionMessage = "保存失败，断点日志已保留，请重试" }
            importProgress = ImportProgressState(
                id: jobID, phase: .completed, total: result.total, processed: result.processed,
                imported: result.items.count, skipped: result.skipped,
                currentFilename: result.wasCancelled
                    ? "已停止，已保留完成的 \(result.processed) 项"
                    : (result.items.isEmpty
                        ? "没有发现新图片"
                        : (result.usedFastIndex ? "快速原位索引完成，预览信息将按需补充" : "已登记，可在画册中浏览")),
                kind: kind,
                estimatedRemainingSeconds: result.wasCancelled ? nil : 0
            )
            if !result.duplicatePaths.isEmpty {
                let comparisonPaths = result.duplicateCandidates.flatMap {
                    [$0.existingPath, $0.incomingPath]
                }
                duplicateImportPaths = Array(Set(duplicateImportPaths + result.duplicatePaths + comparisonPaths)).sorted()
            }
            if !result.duplicateCandidates.isEmpty {
                var queued = Set(duplicateImportCandidates.map(\.queueIdentity))
                duplicateImportCandidates.append(contentsOf: result.duplicateCandidates.filter {
                    queued.insert($0.queueIdentity).inserted
                })
                updateDuplicateImportMessage()
                persistDuplicateImportQueueSoon()
            }
            if saved && result.failure == nil && !result.wasCancelled {
                do { try await Task.detached { try ImportResumeRecord.clear(at: resumeURL) }.value; resumableImport = nil }
                catch { assetActionMessage = "恢复任务清理失败" }
            }
            isImporting = false
            isProjectScanning = false
            imageImportTask = nil
            supplementPendingMetadata()
            scheduleImportProgressDismiss(for: jobID)
            if !result.items.isEmpty {
                NotificationCenter.default.post(name: .importedAssetsAvailable, object: nil)
                // Technical metadata is supplemented separately; importing never starts AI classification.
            }
        }
    }

    func cancelImageImport() {
        guard isImporting, let progress = importProgress else { return }
        imageImportTask?.cancel()
        var stopping = progress
        stopping.currentFilename = "正在停止，已完成的索引会保留…"
        stopping.estimatedRemainingSeconds = nil
        importProgress = stopping
    }

    private func persistImportCheckpoint(
        _ batch: [PendingImportItem],
        jobID: UUID,
        project: ProjectRecord, timing: ImportTiming
    ) async throws {
        guard importProgress?.id == jobID, currentProject.id == project.id else { throw CancellationError() }
        guard !batch.isEmpty else { return }
        let saveStart = Date.now
        try await pendingImportJournalWriter.append(batch, to: Self.pendingImportJournalURL(project: project))
        timing.record("persistence_journal", since: saveStart)
        guard importProgress?.id == jobID, currentProject.id == project.id else { throw CancellationError() }
        pendingPublication.append(contentsOf: batch)
        guard Date.now.timeIntervalSince(lastImportPublication) >= 0.5 else { return }
        lastImportPublication = .now
        let known = Set(pendingImports.map(\.sourceIdentity))
        let published = pendingPublication.filter { !known.contains($0.sourceIdentity) }
        let publicationStart = Date.now
        pendingImports.append(contentsOf: published)
        timing.published()
        timing.record("main_publication", since: publicationStart)
        publishedImportIDs.formUnion(published.map(\.id))
        pendingPublication.removeAll(keepingCapacity: true)
        markContentChanged()
    }

    private func startPendingVisionClassification(for ids: [String], projectID: String) {
        pendingVisionClassificationTask?.cancel()
        let selected = Set(ids)
        let candidates = pendingImports.compactMap { item -> (id: String, path: String)? in
            guard selected.contains(item.id),
                  item.suggestedType == .unclassified,
                  item.localVisionAnalyzedAt == nil else { return nil }
            return (item.id, item.stagedPath)
        }
        guard !candidates.isEmpty else {
            pendingVisionClassificationProgress = nil
            return
        }

        let jobID = UUID()
        pendingVisionClassificationProgress = PendingVisionClassificationProgressState(
            id: jobID, phase: .classifying, processed: 0, total: candidates.count,
            adopted: 0, message: "正在用本机 Vision 补充待分类图片…"
        )
        pendingVisionClassificationTask = Task { [weak self] in
            guard let self else { return }
            var adopted = 0
            for (offset, candidate) in candidates.enumerated() {
                guard !Task.isCancelled, self.currentProject.id == projectID else { return }
                let result = await Task.detached(priority: .utility) {
                    LocalImageClassifier.classify(atPath: candidate.path)
                }.value
                guard !Task.isCancelled,
                      self.currentProject.id == projectID,
                      let index = self.pendingImports.firstIndex(where: { $0.id == candidate.id }) else { continue }
                if self.pendingImports[index].applyLocalClassification(result, expectedType: .unclassified) != nil {
                    let item = self.pendingImports[index]
                    self.pendingImports[index].category = Self.inferredCategory(
                        filename: item.originalSourcePath,
                        type: item.suggestedType
                    )
                    adopted += 1
                }
                self.pendingVisionClassificationProgress = PendingVisionClassificationProgressState(
                    id: jobID, phase: .classifying, processed: offset + 1, total: candidates.count,
                    adopted: adopted, message: "本机 Vision 已分析 \(offset + 1)/\(candidates.count)"
                )
            }
            await self.persistPendingManifest(self.pendingImports, project: self.currentProject)
            self.pendingVisionClassificationProgress = PendingVisionClassificationProgressState(
                id: jobID, phase: .completed, processed: candidates.count, total: candidates.count,
                adopted: adopted, message: "已补充 \(adopted) 项分类建议"
            )
            try? await Task.sleep(for: .seconds(5))
            if self.pendingVisionClassificationProgress?.id == jobID {
                self.pendingVisionClassificationProgress = nil
            }
            self.pendingVisionClassificationTask = nil
        }
    }

    func updatePendingImport(_ id: String, type: AssetType) {
        guard let index = pendingImports.firstIndex(where: { $0.id == id }) else { return }
        pendingImports[index].suggestedType = type
        pendingImports[index].category = Self.inferredCategory(filename: pendingImports[index].originalFilename, type: type)
        persistPendingManifestSoon()
    }
    func bulkSetPendingType(_ ids: [String], type: AssetType) {
        let selected = Set(ids)
        for index in pendingImports.indices where selected.contains(pendingImports[index].id) {
            pendingImports[index].suggestedType = type
        }
        persistPendingManifestSoon()
    }
    func bulkSetPendingCategory(_ ids: [String], category: AssetCategory) {
        let selected = Set(ids)
        for index in pendingImports.indices where selected.contains(pendingImports[index].id) {
            pendingImports[index].category = category
        }
        persistPendingManifestSoon()
    }
    func pendingImport(withID id: String) -> PendingImportItem? { pendingImports.first { $0.id == id } }
    func generationBatch(for item: PendingImportItem) -> GenerationBatchRecord? {
        guard let batchID = item.generationProvenance?.batchID else { return nil }
        return generationBatches.first { $0.id == batchID }
    }

    /// Reveals the original pending-import source in Finder without mutating it.
    func revealPendingImportSource(_ id: String) {
        guard let item = pendingImport(withID: id) else { return }
        let source = URL(fileURLWithPath: item.originalSourcePath)
        let fallback = URL(fileURLWithPath: item.stagedPath)
        let target = fileManager.fileExists(atPath: source.path) ? source : fallback
        guard fileManager.fileExists(atPath: target.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    func copyPendingImportSourcePath(_ id: String) {
        guard let item = pendingImport(withID: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.originalSourcePath, forType: .string)
        showToast("已复制本地原图路径")
    }
    func requestRenamePendingOriginalFile(_ id: String) {
        guard let item = pendingImport(withID: id) else { return }
        let source = URL(fileURLWithPath: item.originalSourcePath)
        guard let name = promptForRename(
            title: "重命名原文件",
            message: "将直接修改 Finder 中的真实文件名；扩展名 .\(source.pathExtension) 保持不变。",
            currentName: source.deletingPathExtension().lastPathComponent
        ) else { return }
        _ = renamePendingOriginalFile(id, toBaseName: name)
    }
    func relinkPendingImportSource(_ id: String) {
        guard let item = pendingImport(withID: id) else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(item.name)”的原图"
        panel.prompt = "使用此图片"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = currentProjectRootURL
        Task {
            let descriptor = await Task.detached(priority: .userInitiated) {
                Self.describe(url: url, root: root)
            }.value
            guard let index = pendingImports.firstIndex(where: { $0.id == id }) else { return }
            pendingImports[index].stagedPath = descriptor.url.path
            pendingImports[index].originalSourcePath = descriptor.url.path
            pendingImports[index].originalFilename = descriptor.url.lastPathComponent
            pendingImports[index].sourceFileID = descriptor.fileID
            pendingImports[index].sourceFileSize = descriptor.fileSize
            pendingImports[index].sourceCreatedAt = descriptor.createdAt
            pendingImports[index].sourceModifiedAt = descriptor.modifiedAt
            pendingImports[index].pixelWidth = descriptor.pixelWidth
            pendingImports[index].pixelHeight = descriptor.pixelHeight
            pendingImports[index].sourceFolderID = nil
            pendingImports[index].sourceRelativePath = descriptor.relativePath
            markContentChanged()
            persistPendingManifestSoon()
            showToast("待确认原图已重新定位")
        }
    }
    func updatePendingImport(_ id: String, preferredName: String) {
        guard let i = pendingImports.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingImports[i].preferredName = cleaned.isEmpty ? nil : cleaned
        pendingImports[i].wasPreferredNameManuallyEdited = true
        persistPendingManifestSoon()
    }
    func updatePendingImport(_ id: String, category: AssetCategory) { guard let i = pendingImports.firstIndex(where: { $0.id == id }) else { return }; pendingImports[i].category = category; persistPendingManifestSoon() }
    func updatePendingImport(_ id: String, manualTags: [String]) { guard let i = pendingImports.firstIndex(where: { $0.id == id }) else { return }; pendingImports[i].manualTags = manualTags; persistPendingManifestSoon() }

    func pendingAISuggestions(in ids: some Sequence<String>) -> [PendingAIAnalysisSuggestion] {
        let scope = Set(ids)
        return pendingImports.compactMap { item in
            guard scope.contains(item.id), let suggestion = item.aiVisionSuggestion else { return nil }
            return suggestion
        }
    }

    func startPendingAIClassification(
        ids: some Sequence<String>,
        configuration: VisionAPIConfiguration,
        client: any VisionModelClient = OpenAICompatibleVisionClient()
    ) {
        pendingAIClassificationTask?.cancel()
        let scope = Set(ids)
        let projectID = currentProject.id
        let candidates = pendingImports.compactMap { item -> VisionAnalysisInput? in
            guard scope.contains(item.id), item.suggestedType == .unclassified else { return nil }
            return VisionAnalysisInput(
                itemID: item.id,
                imagePath: item.stagedPath,
                filename: item.originalFilename,
                relativePath: item.sourceRelativePath,
                currentType: item.suggestedType,
                localVisionLabels: item.localVisionLabels ?? []
            )
        }
        guard !candidates.isEmpty else {
            pendingAIClassificationProgress = PendingAIClassificationProgressState(
                id: UUID(), phase: .completed, processed: 0, total: 0,
                succeeded: 0, failed: 0, message: "当前范围没有待分类图片"
            )
            return
        }

        let jobID = UUID()
        pendingAIClassificationProgress = PendingAIClassificationProgressState(
            id: jobID, phase: .analyzing, processed: 0, total: candidates.count,
            succeeded: 0, failed: 0, message: "准备分析 \(candidates.count) 张待分类图片…"
        )
        pendingAIClassificationTask = Task { [weak self] in
            guard let self else { return }
            var processed = 0
            var succeeded = 0
            var failed = 0
            var latestFailure: String?
            let batchSize = max(1, min(8, configuration.batchSize))

            for start in stride(from: 0, to: candidates.count, by: batchSize) {
                guard !Task.isCancelled, self.currentProject.id == projectID else { return }
                let end = min(start + batchSize, candidates.count)
                let batch = Array(candidates[start..<end])
                let outcomes = await withTaskGroup(of: PendingAIClassificationOutcome.self) { group in
                    for input in batch {
                        group.addTask {
                            do {
                                let suggestion = try await client.analyze(
                                    input: input,
                                    configuration: configuration
                                )
                                return .success(suggestion)
                            } catch {
                                return .failure(itemID: input.itemID, message: error.localizedDescription)
                            }
                        }
                    }
                    var values: [PendingAIClassificationOutcome] = []
                    for await outcome in group { values.append(outcome) }
                    return values
                }

                guard !Task.isCancelled, self.currentProject.id == projectID else { return }
                for outcome in outcomes {
                    processed += 1
                    switch outcome {
                    case .success(let suggestion):
                        guard let index = self.pendingImports.firstIndex(where: { $0.id == suggestion.itemID }) else {
                            failed += 1
                            continue
                        }
                        self.pendingImports[index].aiVisionSuggestion = suggestion
                        succeeded += 1
                    case .failure(_, let message):
                        failed += 1
                        latestFailure = message
                    }
                }
                await self.persistPendingManifest(self.pendingImports, project: self.currentProject)
                self.pendingAIClassificationProgress = PendingAIClassificationProgressState(
                    id: jobID, phase: .analyzing, processed: processed, total: candidates.count,
                    succeeded: succeeded, failed: failed,
                    message: "AI 已分析 \(processed)/\(candidates.count) · 成功 \(succeeded) · 失败 \(failed)"
                )
            }

            let phase: PendingAIClassificationProgressState.Phase = succeeded == 0 ? .failed : .completed
            let suffix = latestFailure.map { "；最近错误：\($0)" } ?? ""
            self.pendingAIClassificationProgress = PendingAIClassificationProgressState(
                id: jobID, phase: phase, processed: processed, total: candidates.count,
                succeeded: succeeded, failed: failed,
                message: "AI 看图整理完成：成功 \(succeeded)，失败 \(failed)\(suffix)"
            )
            self.pendingAIClassificationTask = nil
        }
    }

    func cancelPendingAIClassification() {
        pendingAIClassificationTask?.cancel()
        pendingAIClassificationTask = nil
        if var progress = pendingAIClassificationProgress, progress.phase == .analyzing {
            progress.phase = progress.succeeded > 0 ? .completed : .failed
            progress.message = "已取消；成功结果已保留，可稍后继续分析"
            pendingAIClassificationProgress = progress
        }
    }

    func dismissPendingAIClassificationProgress() {
        guard pendingAIClassificationProgress?.phase != .analyzing else { return }
        pendingAIClassificationProgress = nil
    }

    func updatePendingAISuggestion(
        itemID: String,
        proposedName: String,
        assetType: AssetType,
        tags: [String]
    ) {
        guard let index = pendingImports.firstIndex(where: { $0.id == itemID }),
              var suggestion = pendingImports[index].aiVisionSuggestion,
              suggestion.effectiveDecision == .pending else { return }
        let cleanedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        suggestion.wasEditedByUser = cleanedName != suggestion.proposedName
            || assetType != suggestion.assetType
            || cleanedTags != suggestion.normalizedTags
        suggestion.proposedName = cleanedName
        suggestion.assetType = assetType
        suggestion.styleTags = cleanedTags
        pendingImports[index].aiVisionSuggestion = suggestion
        persistPendingManifestSoon()
    }

    @discardableResult
    func applyPendingAISuggestions(_ ids: some Sequence<String>) -> Int {
        let scope = Set(ids)
        var applied = 0
        for index in pendingImports.indices where scope.contains(pendingImports[index].id) {
            guard pendingImports[index].suggestedType == .unclassified,
                  var suggestion = pendingImports[index].aiVisionSuggestion,
                  suggestion.effectiveDecision == .pending else { continue }
            if suggestion.assetType != .unclassified {
                pendingImports[index].suggestedType = suggestion.assetType
                pendingImports[index].category = Self.inferredCategory(
                    filename: pendingImports[index].originalFilename,
                    type: suggestion.assetType
                )
            }
            if !pendingImports[index].wasPreferredNameManuallyEdited {
                let name = suggestion.proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { pendingImports[index].preferredName = name }
            }
            pendingImports[index].manualTags = Array(Set(
                pendingImports[index].normalizedManualTags + suggestion.normalizedTags
            )).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            suggestion.decision = .applied
            pendingImports[index].aiVisionSuggestion = suggestion
            applied += 1
        }
        if applied > 0 { persistPendingManifestSoon() }
        return applied
    }

    @discardableResult
    func ignorePendingAISuggestions(_ ids: some Sequence<String>) -> Int {
        let scope = Set(ids)
        var ignored = 0
        for index in pendingImports.indices where scope.contains(pendingImports[index].id) {
            guard var suggestion = pendingImports[index].aiVisionSuggestion,
                  suggestion.effectiveDecision == .pending else { continue }
            suggestion.decision = .ignored
            pendingImports[index].aiVisionSuggestion = suggestion
            ignored += 1
        }
        if ignored > 0 { persistPendingManifestSoon() }
        return ignored
    }
    private func persistPendingManifestSoon() {
        pendingManifestSaveTask?.cancel()
        let project = currentProject
        pendingManifestSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            guard self.currentProject.id == project.id else { return }
            await self.persistPendingManifest(self.pendingImports, project: project)
        }
    }

    func flushPendingImportManifest() async {
        pendingManifestSaveTask?.cancel()
        pendingManifestSaveTask = nil
        await persistPendingManifest(pendingImports, project: currentProject)
    }

    private func persistDuplicateImportQueueSoon() {
        duplicateImportQueueSaveTask?.cancel()
        let project = currentProject
        let candidates = duplicateImportCandidates
        duplicateImportQueueSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            await self.persistDuplicateImportQueue(candidates, project: project)
        }
    }

    private func persistDuplicateImportQueue(
        _ candidates: [DuplicateImportCandidate],
        project: ProjectRecord
    ) async {
        duplicateImportQueueRevision &+= 1
        await duplicateImportQueueWriter.write(
            candidates: candidates,
            to: Self.duplicateImportQueueURL(project: project),
            revision: duplicateImportQueueRevision
        )
    }

    func setPendingReviewStatus(_ id: String, status: PendingReviewStatus) {
        guard let index = pendingImports.firstIndex(where: { $0.id == id }) else { return }
        pendingImports[index].reviewStatus = status
        persistPendingManifestSoon()
    }

    @discardableResult
    func keepUnreviewedPendingImports(_ ids: some Sequence<String>) -> Int {
        let scope = Set(ids)
        var changed = 0
        for index in pendingImports.indices where scope.contains(pendingImports[index].id) && pendingImports[index].effectiveReviewStatus == .unreviewed {
            pendingImports[index].reviewStatus = .kept
            changed += 1
        }
        if changed > 0 { persistPendingManifestSoon() }
        return changed
    }

    func confirmKeptPendingImports() {
        confirmPendingImports(Set(pendingImports.filter { $0.effectiveReviewStatus == .kept }.map(\.id)))
    }

    func trashDiscardedPendingImports(_ ids: some Sequence<String>) async -> [String] {
        let scope = Set(ids)
        let project = currentProject
        let projectID = project.id
        var deleted: [String] = []
        for item in pendingImports where scope.contains(item.id) && item.effectiveReviewStatus == .discarded {
            guard currentProject.id == projectID else { break }
            let source = URL(fileURLWithPath: item.originalSourcePath)
            guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  Int64(values.fileSize ?? -1) == item.sourceFileSize,
                  values.contentModificationDate == item.sourceModifiedAt else { continue }
            do {
                try pendingSourceTrashService.moveToTrash(source)
                let staged = URL(fileURLWithPath: item.stagedPath).standardizedFileURL
                if staged.path != source.standardizedFileURL.path,
                   Self.isManagedPath(staged.path, projectRoot: currentProjectRootURL) {
                    try? fileManager.removeItem(at: staged)
                }
                deleted.append(item.id)
            } catch { continue }
        }
        guard !deleted.isEmpty, currentProject.id == projectID else { return deleted }
        pendingImports.removeAll { deleted.contains($0.id) }
        markContentChanged()
        await flushPendingImportManifest()
        return deleted
    }

    /// Moves one reviewed source to the system Trash through the same guarded
    /// path as batch cleanup.  The source must still match its staged manifest
    /// metadata, so an unrelated user file can never be removed by this action.
    @discardableResult
    func trashPendingImportSource(_ id: String) async -> Bool {
        guard pendingImport(withID: id) != nil else { return false }
        setPendingReviewStatus(id, status: .discarded)
        return await trashDiscardedPendingImports([id]).contains(id)
    }

    func confirmPendingImports(_ ids: Set<String>) {
        guard !isImporting else { showToast("正在处理图片，请稍候"); return }
        let selected = pendingImports.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { showToast("请先选择要导入的图片"); return }
        importDismissTask?.cancel()
        let project = currentProject
        let projectID = project.id
        let root = currentProjectRootURL
        let startingSequence = nextAssetSequence
        let jobID = UUID()
        isImporting = true
        isProjectScanning = false
        importProgress = ImportProgressState(
            id: jobID, phase: .importing, total: selected.count, processed: 0, imported: 0, skipped: 0,
            currentFilename: selected.first?.originalFilename ?? "正在确认入库…", kind: .confirmImport
        )
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Self.performPendingConfirmation(
                    items: selected, projectID: projectID, projectRoot: root,
                    startingAt: startingSequence, jobID: jobID
                ) { progress in
                    await self.applyImportProgress(progress)
                }
            }.value
            guard currentProject.id == projectID else { return }
            assets.append(contentsOf: result.assets)
            pendingImports.removeAll { result.completedIDs.contains($0.id) }
            await persistPendingManifest(pendingImports, project: project)
            rebuildDerivedState()
            scheduleSave()
            isImporting = false
            let processed = result.assets.count + result.failed
            importProgress = ImportProgressState(
                id: jobID, phase: .completed, total: selected.count, processed: processed,
                imported: result.assets.count, skipped: result.failed,
                currentFilename: result.failed == 0 ? "已登记为正式资产" : "有 \(result.failed) 项未完成，已保留在待确认区", kind: .confirmImport
            )
            scheduleImportProgressDismiss(for: jobID)
            showToast("已确认导入 \(result.assets.count) 项资产")
        }
    }

    func discardPendingImports(_ ids: Set<String>) {
        let discarded = pendingImports.filter { ids.contains($0.id) }
        guard !discarded.isEmpty else { return }
        for item in discarded {
            // New imports reference the user's source in place. Only remove a
            // legacy software-managed staging copy when it is a different file.
            let staged = URL(fileURLWithPath: item.stagedPath).standardizedFileURL.path
            let original = URL(fileURLWithPath: item.originalSourcePath).standardizedFileURL.path
            if staged != original, Self.isManagedPath(staged, projectRoot: currentProjectRootURL) {
                try? fileManager.removeItem(atPath: staged)
            }
        }
        pendingImports.removeAll { ids.contains($0.id) }
        // Local-folder galleries mix confirmed assets with pending original-place
        // references. Publishing the array alone recomputes SwiftUI, but the
        // AppKit diffable gallery intentionally keys snapshot changes off this
        // revision. Without it, the removed card remains visible until the view
        // changes or the app restarts.
        markContentChanged()
        let items = pendingImports
        let project = currentProject
        Task { await persistPendingManifest(items, project: project) }
        showToast("已移出待确认 \(discarded.count) 项，原文件未受影响")
    }

    func revealPendingImportDirectory() {
        let directory = pendingImportDirectoryURL
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func revealCodexInboxDirectory() {
        let directory = codexInboxDirectoryURL
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            assetActionMessage = "无法打开 Codex 候选区：\(error.localizedDescription)"
        }
    }

    func refreshCodexInbox(showToast showsToast: Bool = true) async {
        guard !isLoadingProject else { return }
        let token = projectLoadToken
        let project = currentProject
        let root = currentProjectRootURL
        let pendingSnapshot = pendingImports
        let assetSnapshot = assets
        let result = await Task.detached(priority: .utility) {
            CodexGenerationIntake.scan(
                project: project,
                projectRoot: root,
                existingPending: pendingSnapshot,
                existingAssets: assetSnapshot
            )
        }.value
        guard !Task.isCancelled, projectLoadToken == token, currentProject.id == project.id else { return }

        var batchesByID = Dictionary(uniqueKeysWithValues: generationBatches.map { ($0.id, $0) })
        var batchesChanged = false
        for batch in result.batches where batchesByID[batch.id] != batch {
            batchesByID[batch.id] = batch
            batchesChanged = true
        }
        if batchesChanged {
            generationBatches = batchesByID.values.sorted { $0.createdAt < $1.createdAt }
            scheduleSave()
        }

        let knownIDs = Set(pendingImports.map(\.id))
        let newItems = result.pendingItems.filter { !knownIDs.contains($0.id) }
        guard !newItems.isEmpty else {
            if showsToast {
                let detail = result.invalidCount > 0 ? "；\(result.invalidCount) 项 manifest 无效" : ""
                showToast("Codex 候选区没有新图片\(detail)")
            }
            return
        }
        pendingImports.append(contentsOf: newItems)
        await persistPendingManifest(pendingImports, project: project)
        NotificationCenter.default.post(name: .importedAssetsAvailable, object: nil)
        if showsToast {
            let duplicateText = result.duplicateCount > 0 ? "，已跳过 \(result.duplicateCount) 张重复图" : ""
            showToast("已接收 \(newItems.count) 张 Codex 生成候选\(duplicateText)")
        }
    }

    private func startCodexInboxWatcher(project: ProjectRecord, root: URL, token: UUID) {
        codexInboxWatchTask?.cancel()
        let applicationSupportRoot = rootURL
        codexInboxWatchTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try CodexGenerationIntake.writeProjectContext(
                        project: project,
                        projectRoot: root,
                        applicationSupportRoot: applicationSupportRoot
                    )
                }.value
            } catch {
                guard let self, self.projectLoadToken == token, self.currentProject.id == project.id else { return }
                self.assetActionMessage = "Codex 候选区初始化失败：\(error.localizedDescription)"
                return
            }
            guard let self, self.projectLoadToken == token, self.currentProject.id == project.id else { return }
            await self.refreshCodexInbox(showToast: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.projectLoadToken == token, self.currentProject.id == project.id else { return }
                await self.refreshCodexInbox(showToast: false)
            }
        }
    }

    /// 保留为内部迁移和自测入口；界面的选择、拖入和扫描一律先进待导入区。
    func importImages(_ urls: [URL]) {
        guard !isImporting else { showToast("正在处理图片，请稍候"); return }
        importDismissTask?.cancel()
        let projectID = currentProject.id
        let root = currentProjectRootURL
        let knownPaths = Set(assets.map { URL(fileURLWithPath: $0.imagePath).standardizedFileURL.path })
        let sequence = nextAssetSequence
        let jobID = UUID()
        isImporting = true
        isProjectScanning = false
        importProgress = ImportProgressState(id: jobID, phase: .scanning, total: 0, processed: 0, imported: 0, skipped: 0, currentFilename: "正在扫描所选文件…")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Self.prepareReferences(urls: urls, root: root, projectID: projectID, knownPaths: knownPaths, startingAt: sequence, jobID: jobID) { progress in
                    await self.applyImportProgress(progress)
                }
            }.value
            guard currentProject.id == projectID else { return }
            assets.append(contentsOf: result.assets)
            isImporting = false
            importProgress = ImportProgressState(id: jobID, phase: .completed, total: result.assets.count + result.skipped, processed: result.assets.count + result.skipped, imported: result.assets.count, skipped: result.skipped, currentFilename: "所有图片已处理完成")
            scheduleImportProgressDismiss(for: jobID)
            rebuildDerivedState(); scheduleSave()
        }
    }

    /// 全局素材进入当前项目时只创建候选引用，不复制或移动源文件。
    func addGlobalMaterialCandidate(_ material: MaterialRecord) {
        guard material.kind == .image else {
            showToast("图片候选用于视觉资产；音视频请在素材总库关联项目和镜头")
            return
        }
        guard let location = material.fileLocation, location.exists else {
            showToast("该素材文件已失联，请先恢复文件")
            return
        }
        let path = location.path
        guard !assets.contains(where: { $0.materialID == material.id && $0.deletedAt == nil }) else {
            showToast("该素材已是当前项目候选")
            return
        }
        let url = URL(fileURLWithPath: path)
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let dimensions = material.kind == .image ? Self.imageDimensions(at: url) : (nil, nil)
        assets.append(AssetItem(
            id: UUID().uuidString, name: material.name, type: .unclassified, imagePath: path,
            originalFilename: material.originalFilename, decision: .pending, note: material.note, reuse: .b,
            project: currentProject.name, episodes: [], candidatePlan: .none, version: "v01", purpose: .pending,
            category: .pending, qaResult: .pending, productionStatus: .pendingConfirm,
            assetDescription: "来自全局素材库", repairReason: "", fingerprint: material.fingerprint,
            shapeState: "", promptSource: "", generationPlatform: "", position: CanvasPoint(x: 0, y: 0),
            createdAt: .now, projectID: currentProject.id,
            sourceFileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            sourceCreatedAt: attributes?[.creationDate] as? Date,
            sourceModifiedAt: attributes?[.modificationDate] as? Date,
            isSourceMissing: !fileManager.fileExists(atPath: path), pixelWidth: dimensions.0, pixelHeight: dimensions.1,
            tags: material.tags, rating: material.rating, sourceURL: material.sourceURL, materialID: material.id
        ))
        rebuildDerivedState(); scheduleSave()
        showToast("已作为候选加入当前项目")
    }

    private func applyImportProgress(_ progress: ImportProgressState) {
        guard isImporting, importProgress?.id == progress.id, importProgress?.phase != .completed else { return }
        let now = Date.now
        let isFinalUpdate = progress.total > 0 && progress.processed >= progress.total
        guard isFinalUpdate || now.timeIntervalSince(lastImportProgressUpdate) >= 0.12 else { return }
        lastImportProgressUpdate = now
        var displayed = progress
        displayed.estimatedRemainingSeconds = importProgressEstimator.estimate(
            jobID: progress.id,
            isActive: progress.phase == .importing,
            isCompleted: progress.phase == .completed,
            processed: progress.processed,
            total: progress.total,
            at: now
        )
        importProgress = displayed
    }

    func dismissImportProgress() {
        guard !isImporting else { return }
        importDismissTask?.cancel()
        importDismissTask = nil
        importProgress = nil
    }
    func dismissDuplicateImportMessage() {
        duplicateImportMessage = nil
    }
    func revealDuplicateImportsInFinder() {
        let urls = duplicateImportPaths.prefix(50).map(URL.init(fileURLWithPath:))
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func resolveDuplicateImport(
        _ candidateID: UUID,
        decision: DuplicateImportDecision,
        applyToAll: Bool
    ) {
        let resolved = applyToAll
            ? duplicateImportCandidates
            : duplicateImportCandidates.filter { $0.id == candidateID }
        guard !resolved.isEmpty else { return }

        let resolvedIDs = Set(resolved.map(\.id))
        duplicateImportCandidates.removeAll { resolvedIDs.contains($0.id) }

        if decision == .useExisting {
            let incomingIDs = Set(resolved.map { $0.incomingItem.id })
            pendingImports.removeAll { incomingIDs.contains($0.id) }
            markContentChanged()
            persistPendingManifestSoon()
        }
        if decision == .keepBoth {
            let existingIDs = Set(pendingImports.map(\.id))
            let addedItems = resolved.map(\.incomingItem).filter { !existingIDs.contains($0.id) }
            pendingImports.append(contentsOf: addedItems)
            if !addedItems.isEmpty {
                persistPendingManifestSoon()
                NotificationCenter.default.post(name: .importedAssetsAvailable, object: nil)
                startPendingVisionClassification(for: pendingImports.map(\.id), projectID: currentProject.id)
                showToast("已保留 \(addedItems.count) 张重复图片的两个文件")
            }
        }

        updateDuplicateImportMessage()
        persistDuplicateImportQueueSoon()
    }

    private func updateDuplicateImportMessage() {
        guard !duplicateImportCandidates.isEmpty else {
            duplicateImportMessage = nil
            return
        }
        duplicateImportMessage = "发现 \(duplicateImportCandidates.count) 组内容完全相同、位置不同的照片。请选择使用现有文件或保留两者；软件不会删除任何原图。"
    }
    func dismissExportProgress() { guard exportProgress?.phase != .exporting else { return }; exportProgress = nil }

    private func scheduleImportProgressDismiss(for jobID: UUID) {
        importDismissTask?.cancel()
        importDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  self.importProgress?.id == jobID,
                  !self.isImporting else { return }
            self.importProgress = nil
            self.importDismissTask = nil
        }
    }

    func updateAsset(_ id: String, _ update: (inout AssetItem) -> Void) {
        if let pendingID = pendingImportID(fromGalleryID: id) {
            guard let managedID = promotePendingImports([pendingID])[pendingID] else {
                assetActionMessage = "该待确认素材已不存在，请刷新后重试。"
                return
            }
            updateAsset(managedID, update)
            return
        }
        guard let index = assetIndex[id] else { return }
        let before = assets[index]
        update(&assets[index])
        let after = assets[index]
        if affectsDerivedState(before, after) {
            rebuildDerivedState()
        } else {
            replaceCachedAsset(after)
        }
        scheduleSave()
        if after.starRating == 5, before.starRating != after.starRating {
            copyFiveStarAssetIntoManagedLibrary(id)
        }
        if after.isMaster, !before.isMaster {
            copyCommonAssetIntoManagedLibrary(id)
        }
    }

    func setRating(_ id: String, rating: Int) {
        if let pendingID = pendingImportID(fromGalleryID: id) {
            guard let managedID = promotePendingImports([pendingID])[pendingID] else {
                assetActionMessage = "该待确认素材已不存在，请刷新后重试。"
                return
            }
            setRating(managedID, rating: rating)
            return
        }
        guard let index = assetIndex[id] else { return }
        assets[index].rating = min(5, max(0, rating))
        rebuildDerivedState()
        scheduleSave()
        if assets[index].starRating == 5 {
            showToast("已设为 5 星，正在检查 SSD 资产库副本")
            copyFiveStarAssetIntoManagedLibrary(id)
        } else {
            showToast(assets[index].starRating == 0 ? "已清除评分" : "已设为 \(assets[index].starRating) 星")
        }
    }

    /// Registers pending original-place references as normal project assets so
    /// gallery actions (rating, master, export, metadata) never silently ignore
    /// a visible card. No source file is copied or moved here.
    @discardableResult
    func promotePendingImports(_ ids: Set<String>) -> [String: String] {
        let selected = pendingImports.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return [:] }
        let startingSequence = nextAssetSequence
        var mapping: [String: String] = [:]
        var promoted: [AssetItem] = []
        promoted.reserveCapacity(selected.count)
        for (offset, item) in selected.enumerated() {
            let asset = registeredAsset(from: item, sequence: startingSequence + offset, deletedAt: nil)
            mapping[item.id] = asset.id
            promoted.append(asset)
        }
        assets.append(contentsOf: promoted)
        pendingImports.removeAll { ids.contains($0.id) }
        rebuildDerivedState()
        scheduleSave()
        let items = pendingImports
        let project = currentProject
        Task { await persistPendingManifest(items, project: project) }
        return mapping
    }
    func moveAssetToTrash(_ id: String) {
        if let pendingID = pendingImportID(fromGalleryID: id) {
            discardPendingImports([pendingID])
            return
        }
        guard let index = assetIndex[id], assets[index].deletedAt == nil else { return }
        assets[index].deletedAt = Date(); rebuildDerivedState(); scheduleSave()
        undoTrashAssetID = id; toast = "已移入回收站"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.undoTrashAssetID == id else { return }
            self.undoTrashAssetID = nil
            if self.toast == "已移入回收站" { self.toast = nil }
        }
    }

    /// Compatibility entry point for older callers. Pending imports are not
    /// formal assets, so removal only discards the pending record and leaves
    /// the original file in place; it never manufactures an App Trash asset.
    func movePendingImportToTrash(_ id: String) {
        discardPendingImports([id])
    }

    private func registeredAsset(from item: PendingImportItem, sequence: Int, deletedAt: Date?) -> AssetItem {
        let original = URL(fileURLWithPath: item.originalSourcePath).standardizedFileURL
        let staged = URL(fileURLWithPath: item.stagedPath).standardizedFileURL
        let source = fileManager.fileExists(atPath: original.path) ? original : staged
        var asset = item.previewAsset
        asset.id = "ASSET-\(String(format: "%03d", sequence))"
        asset.imagePath = source.path
        asset.originalFilename = item.originalFilename
        asset.projectID = currentProject.id
        asset.sourceFolderID = item.sourceFolderID
        asset.sourceOriginalPath = item.originalSourcePath
        asset.sourceRelativePath = item.sourceRelativePath
        asset.sourceFileID = item.sourceFileID
        asset.sourceFileSize = item.sourceFileSize
        asset.sourceCreatedAt = item.sourceCreatedAt
        asset.sourceModifiedAt = item.sourceModifiedAt
        asset.importSourceFileID = item.sourceFileID
        asset.importSourceFileSize = item.sourceFileSize
        asset.importSourceModifiedAt = item.sourceModifiedAt
        asset.exportName = item.name
        asset.tags = item.normalizedManualTags
        asset.purpose = item.suggestedPurpose ?? .pending
        asset.generationProvenance = item.generationProvenance
        asset.isSourceMissing = !fileManager.fileExists(atPath: source.path)
        asset.position = CanvasPoint(
            x: 510 + CGFloat((sequence - 1) % 3) * 230,
            y: 80 + CGFloat((sequence - 1) / 3) * 205
        )
        asset.deletedAt = deletedAt
        if let provenance = item.generationProvenance {
            asset.generationPlatform = provenance.generationPlatform
            asset.promptSource = "Codex任务：\(provenance.taskTitle) · 批次 \(provenance.batchID)"
        }
        return asset
    }

    private func pendingImportID(fromGalleryID id: String) -> String? {
        let prefix = "PENDING-"
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    func moveAssetsToTrash(_ ids: Set<String>) {
        let now = Date()
        var updated = 0
        for id in ids {
            if let index = assetIndex[id], assets[index].deletedAt == nil {
                assets[index].deletedAt = now
                updated += 1
            }
        }
        guard updated > 0 else {
            if !ids.isEmpty { assetActionMessage = "没有可移入回收站的有效资产。" }
            return
        }
        rebuildDerivedState(); scheduleSave(); showToast("已将 \(updated) 项移入回收站")
    }

    func restoreAsset(_ id: String) {
        guard let index = assetIndex[id], assets[index].deletedAt != nil else { return }
        assets[index].deletedAt = nil
        if undoTrashAssetID == id { undoTrashAssetID = nil }
        rebuildDerivedState(); scheduleSave(); showToast("素材已恢复")
    }
    func restoreAssets(_ ids: Set<String>) {
        var restored = 0
        for id in ids {
            guard let index = assetIndex[id], assets[index].deletedAt != nil else { continue }
            assets[index].deletedAt = nil
            restored += 1
        }
        guard restored > 0 else { return }
        if let undoTrashAssetID, ids.contains(undoTrashAssetID) { self.undoTrashAssetID = nil }
        rebuildDerivedState(); scheduleSave(); showToast("已恢复 \(restored) 项素材")
    }
    func undoLastTrash() { if let id = undoTrashAssetID { restoreAsset(id) } }
    func permanentlyDeleteAsset(_ id: String) {
        guard assets.contains(where: { $0.id == id && $0.deletedAt != nil }) else { return }
        relations.removeAll { $0.assetId == id }; exportNames.removeValue(forKey: id); assets.removeAll { $0.id == id }
        if undoTrashAssetID == id { undoTrashAssetID = nil }
        rebuildDerivedState(); scheduleSave(); showToast("记录已永久删除，原图未受影响")
    }
    func permanentlyDeleteAssets(_ ids: Set<String>) {
        let deletable = Set(assets.lazy.filter { ids.contains($0.id) && $0.deletedAt != nil }.map(\.id))
        guard !deletable.isEmpty else { return }
        relations.removeAll { deletable.contains($0.assetId) }
        for id in deletable { exportNames.removeValue(forKey: id) }
        assets.removeAll { deletable.contains($0.id) }
        if let undoTrashAssetID, deletable.contains(undoTrashAssetID) { self.undoTrashAssetID = nil }
        rebuildDerivedState(); scheduleSave(); showToast("已永久删除 \(deletable.count) 项记录，原图未受影响")
    }
    func bulkSetType(_ ids: Set<String>, type: AssetType) { bulkUpdate(ids) { $0.type = type } }
    func bulkSetDecision(_ ids: Set<String>, decision: UserDecision) { bulkUpdate(ids) { $0.decision = decision } }
    func bulkSetRating(_ ids: Set<String>, rating: Int) {
        let normalized = min(5, max(0, rating))
        var updated: [String] = []
        for id in ids {
            guard let index = assetIndex[id] else { continue }
            assets[index].rating = normalized
            updated.append(id)
        }
        guard !updated.isEmpty else {
            if !ids.isEmpty { assetActionMessage = "没有可评分的有效资产。" }
            return
        }
        rebuildDerivedState(); scheduleSave(); showToast("已更新 \(updated.count) 项资产")
        if normalized == 5 { updated.forEach { copyFiveStarAssetIntoManagedLibrary($0) } }
    }
    func bulkSetMaster(_ ids: Set<String>, isMaster: Bool) {
        var updated = 0
        var newlyAdded: [String] = []
        for id in ids {
            guard let index = assetIndex[id] else { continue }
            if isMaster, !assets[index].isMaster { newlyAdded.append(id) }
            assets[index].isMasterAsset = isMaster
            updated += 1
        }
        guard updated > 0 else {
            if !ids.isEmpty { assetActionMessage = "没有可更新的有效资产。" }
            return
        }
        rebuildDerivedState(); scheduleSave()
        if isMaster {
            showToast("已加入通用资产 \(updated) 项，正在检查 SSD 副本")
            newlyAdded.forEach { copyCommonAssetIntoManagedLibrary($0, showsToast: false) }
        } else {
            showToast("已移出通用资产 \(updated) 项；SSD 副本和原图均保留")
        }
    }
    func bulkAddTags(_ ids: Set<String>, tags: [String]) {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        bulkUpdate(ids) { asset in asset.tags = Array(Set(asset.normalizedTags + cleaned)).sorted() }
    }
    private func bulkUpdate(_ ids: Set<String>, update: (inout AssetItem) -> Void) {
        var updated = 0
        for id in ids {
            if let index = assetIndex[id] {
                update(&assets[index])
                updated += 1
            }
        }
        guard updated > 0 else {
            if !ids.isEmpty { assetActionMessage = "没有可更新的有效资产。" }
            return
        }
        rebuildDerivedState(); scheduleSave(); showToast("已更新 \(updated) 项资产")
    }

    /// 1–4 星保持原位；5 星和明确加入的通用资产分别复制到 SSD 受管目录。
    /// 已生成的受管副本不会因降星或移出通用资产而自动删除；用户原图始终不移动、不删除。
    private func copyFiveStarAssetIntoManagedLibrary(_ id: String, showsToast: Bool = true) {
        copyAssetIntoManagedLibrary(id, target: .fiveStar, showsToast: showsToast)
    }

    private func copyCommonAssetIntoManagedLibrary(_ id: String, showsToast: Bool = true) {
        copyAssetIntoManagedLibrary(id, target: .common, showsToast: showsToast)
    }

    private func copyAssetIntoManagedLibrary(
        _ id: String,
        target: ManagedLibraryCopyTarget,
        showsToast: Bool
    ) {
        guard let index = assetIndex[id], assets[index].deletedAt == nil else { return }
        let asset = assets[index]
        guard target == .fiveStar ? asset.starRating == 5 : asset.isMaster else { return }
        let operationKey = "\(id)|\(target.rawValue)"
        guard managedCopyingKeys.insert(operationKey).inserted else { return }
        let project = currentProject
        let projectID = project.id
        let projectRoot = currentProjectRootURL
        guard let availableSource = Self.bestAvailableSource(for: asset) else {
            managedCopyingKeys.remove(operationKey)
            assetActionMessage = target == .fiveStar
                ? "五星资产复制失败：当前没有可用原图。"
                : "通用资产复制失败：当前没有可用原图。"
            return
        }
        let source = URL(fileURLWithPath: availableSource.path).standardizedFileURL
        guard let libraryRoot = Self.fiveStarLibraryRoot(
            project: project,
            projectRoot: projectRoot,
            ssdRoot: managedLibrarySSDURL
        ) else {
            managedCopyingKeys.remove(operationKey)
            assetActionMessage = target == .fiveStar
                ? "SSD-1TB 未连接，五星资产仍保持原位管理；连接 SSD 后重新打开项目即可补齐。"
                : "SSD-1TB 未连接，通用资产仍保持原位管理；连接 SSD 后重新打开项目即可补齐。"
            return
        }
        let managedRootName = target == .fiveStar ? "05_五星精选" : "06_通用资产"
        let managedRoot = libraryRoot.appendingPathComponent(managedRootName, isDirectory: true)
        let managedFolderName = target == .fiveStar
            ? Self.managedFolderName(for: asset)
            : Self.managedTypeFolderName(for: asset)
        let folder = managedRoot.appendingPathComponent(managedFolderName, isDirectory: true)
        let folderPath = folder.standardizedFileURL.path
        let existingTargetCopy = asset.allSourceVersions.contains { version in
            version.path.hasPrefix(folderPath + "/") && fileManager.fileExists(atPath: version.path)
        }
        if existingTargetCopy {
            managedCopyingKeys.remove(operationKey)
            return
        }
        let libraryPath = libraryRoot.standardizedFileURL.path

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<SourceDescriptor, Error> in
                do {
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = Self.uniqueFile(named: source.lastPathComponent, in: folder)
                    try FileManager.default.copyItem(at: source, to: destination)
                    return .success(Self.describe(url: destination, root: projectRoot))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.managedCopyingKeys.remove(operationKey)
            guard self.currentProject.id == projectID,
                  let currentIndex = self.assetIndex[id],
                  (target == .fiveStar
                    ? self.assets[currentIndex].starRating == 5
                    : self.assets[currentIndex].isMaster) else { return }
            switch result {
            case let .success(descriptor):
                var managed = self.assets[currentIndex]
                let originalRelativePath = managed.sourceRelativePath
                if (managed.sourceOriginalPath == nil || managed.sourceOriginalPath?.isEmpty == true),
                   !source.path.hasPrefix(libraryPath + "/") {
                    managed.sourceOriginalPath = source.path
                }
                self.apply(descriptor: descriptor, to: &managed, archiveCurrent: true)
                managed.sourceRelativePath = originalRelativePath
                self.assets[currentIndex] = managed
                self.rebuildDerivedState(); self.scheduleSave()
                if showsToast {
                    let label = target == .fiveStar ? "五星资产" : "通用资产"
                    self.showToast("\(label)已复制到 SSD · \(managedFolderName)")
                }
            case let .failure(error):
                let label = target == .fiveStar ? "五星资产" : "通用资产"
                self.assetActionMessage = "\(label)复制失败，仍保留当前文件：\(error.localizedDescription)"
            }
        }
    }

    private func syncManagedAssetsIntoLibrary() {
        for asset in assets where asset.deletedAt == nil {
            if asset.starRating == 5 {
                copyFiveStarAssetIntoManagedLibrary(asset.id, showsToast: false)
            }
            if asset.isMaster {
                copyCommonAssetIntoManagedLibrary(asset.id, showsToast: false)
            }
        }
    }

    func addToExportLibrary(_ ids: Set<String>) {
        var added = 0
        for id in ids {
            guard let index = assetIndex[id] else { continue }
            exportNames[id] = assets[index].effectiveExportName
            assets[index].lastUsedAt = .now
            added += 1
        }
        guard added > 0 else {
            if !ids.isEmpty { assetActionMessage = "没有可加入导出库的有效资产。" }
            return
        }
        rebuildDerivedState(); scheduleSave(); showToast("已加入导出库 \(added) 项")
    }
    func removeFromExportLibrary(_ id: String) { exportNames.removeValue(forKey: id); rebuildDerivedState(); scheduleSave() }
    func updateExportName(_ id: String, name: String) { guard exportNames[id] != nil else { return }; exportNames[id] = name; scheduleSave() }

    func chooseExportDestination() {
        let invalid = exportIssues()
        guard invalid.isEmpty else { exportValidationMessage = invalid.joined(separator: "\n"); return }
        let panel = NSOpenPanel()
        panel.title = "选择导出位置"
        panel.prompt = "导出到这里"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportLibrary(to: destination)
    }

    func exportLibrary(to destination: URL) {
        let selected = exportAssets
        let names = exportNames
        let project = currentProject
        let jobID = UUID()
        exportValidationMessage = nil
        exportProgress = ExportProgressState(id: jobID, phase: .validating, total: selected.count, processed: 0, succeeded: 0, failed: 0, currentFilename: "正在检查原图…", resultPath: nil, message: "")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Self.performExport(assets: selected, exportNames: names, project: project, destination: destination, jobID: jobID) { progress in
                    await self.applyExportProgress(progress)
                }
            }.value
            exportProgress = result
        }
    }

    private func applyExportProgress(_ progress: ExportProgressState) {
        let now = Date.now
        let isFinalUpdate = progress.total > 0 && progress.processed >= progress.total
        guard isFinalUpdate || now.timeIntervalSince(lastExportProgressUpdate) >= 0.08 else { return }
        lastExportProgressUpdate = now
        exportProgress = progress
    }

    func exportIssues() -> [String] {
        if exportAssets.isEmpty { return ["导出库为空，请先选择素材加入导出库。"] }
        return exportHealthIssues()
            .filter { $0.severity == .blocking }
            .map { "\($0.assetName)：\($0.message)" }
    }

    func exportHealthIssues() -> [ExportHealthIssue] {
        ExportHealthAnalyzer.analyze(assets: exportAssets, exportNames: exportNames)
    }

    func exportCSV() {
        let panel = NSSavePanel(); panel.title = "导出资产表"; panel.nameFieldStringValue = "\(currentProject.name)_资产表_\(Date.now.formatted(.iso8601.year().month().day())).csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Self.csvManifest(assets: activeAssets, exportedNames: [:], exportedSources: [:])
        try? text.write(to: url, atomically: true, encoding: .utf8); showToast("资产表已导出")
    }

    private func promptForRename(title: String, message: String, currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: currentName)
        field.placeholderString = "输入新名称"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func updateIndexedFilePath(from oldPath: String, to newPath: String) {
        let oldStandardized = URL(fileURLWithPath: oldPath).standardizedFileURL.path
        let newURL = URL(fileURLWithPath: newPath).standardizedFileURL
        for index in assets.indices {
            var changed = false
            if URL(fileURLWithPath: assets[index].imagePath).standardizedFileURL.path == oldStandardized {
                assets[index].imagePath = newURL.path
                assets[index].thumbnailKey = nil
                changed = true
            }
            if let sourcePath = assets[index].sourceOriginalPath,
               URL(fileURLWithPath: sourcePath).standardizedFileURL.path == oldStandardized {
                assets[index].sourceOriginalPath = newURL.path
                changed = true
            }
            if let importPath = assets[index].importSourcePath,
               URL(fileURLWithPath: importPath).standardizedFileURL.path == oldStandardized {
                assets[index].importSourcePath = newURL.path
                changed = true
            }
            if var versions = assets[index].sourceVersions {
                for versionIndex in versions.indices where URL(fileURLWithPath: versions[versionIndex].path).standardizedFileURL.path == oldStandardized {
                    versions[versionIndex].path = newURL.path
                    versions[versionIndex].filename = newURL.lastPathComponent
                    changed = true
                }
                assets[index].sourceVersions = versions
            }
            if changed {
                assets[index].originalFilename = newURL.lastPathComponent
                if let sourceID = assets[index].sourceFolderID,
                   let folder = localFolders.first(where: { $0.id == sourceID }) {
                    assets[index].sourceRelativePath = Self.relativePath(
                        of: newURL, root: URL(fileURLWithPath: folder.rootPath)
                    )
                }
            }
        }
        for index in pendingImports.indices {
            var changed = false
            if URL(fileURLWithPath: pendingImports[index].stagedPath).standardizedFileURL.path == oldStandardized {
                pendingImports[index].stagedPath = newURL.path
                changed = true
            }
            if URL(fileURLWithPath: pendingImports[index].originalSourcePath).standardizedFileURL.path == oldStandardized {
                pendingImports[index].originalSourcePath = newURL.path
                changed = true
            }
            if changed {
                pendingImports[index].originalFilename = newURL.lastPathComponent
                if let sourceID = pendingImports[index].sourceFolderID,
                   let folder = localFolders.first(where: { $0.id == sourceID }) {
                    pendingImports[index].sourceRelativePath = Self.relativePath(
                        of: newURL, root: URL(fileURLWithPath: folder.rootPath)
                    )
                }
            }
        }
        duplicateImportPaths = duplicateImportPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path == oldStandardized ? newURL.path : $0
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        hasPendingChanges = true
        saveGeneration &+= 1
        let generation = saveGeneration
        let snapshot = currentSnapshot
        let database = database
        let projectID = currentProject.id
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                try await database.replace(with: snapshot)
                guard generation == saveGeneration else { return }
                hasPendingChanges = false
                saveTask = nil
                cache(snapshot: snapshot, projectID: projectID)
            } catch {
                guard generation == saveGeneration else { return }
                showToast(error.localizedDescription)
            }
        }
    }

    func flushCurrentProject() async {
        guard hasPendingChanges else {
            saveTask?.cancel()
            saveTask = nil
            return
        }
        saveTask?.cancel()
        saveTask = nil
        let generation = saveGeneration
        let snapshot = currentSnapshot
        do {
            try await database.replace(with: snapshot)
            guard generation == saveGeneration else { return }
            hasPendingChanges = false
            cache(snapshot: snapshot, projectID: currentProject.id)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func saveNow() { Task { await flushCurrentProject() } }

    private var currentSnapshot: ProjectSnapshot {
        ProjectSnapshot(
            library: LibraryData(
                assets: assets,
                groups: groups,
                relations: relations,
                assetStacks: assetStacks.isEmpty ? nil : assetStacks,
                scriptExtractions: scriptExtractions.isEmpty ? nil : scriptExtractions,
                generationBatches: generationBatches
            ),
            exportNames: exportNames,
            localFolders: localFolders
        )
    }

    private func rebuildDerivedState() {
        applyDerivedState(Self.makeDerivedState(assets: assets, exportNames: exportNames))
    }

    nonisolated private static func prepareProjectSnapshot(_ source: ProjectSnapshot) -> PreparedProjectSnapshot {
        var snapshot = source
        var normalizedLegacyLocations = false
        snapshot.library.assets = source.library.assets.map { asset in
            guard asset.importSourcePath != nil else { return asset }
            var normalized = asset
            normalized.importSourcePath = nil
            normalizedLegacyLocations = true
            return normalized
        }
        return PreparedProjectSnapshot(
            snapshot: snapshot,
            derived: makeDerivedState(assets: snapshot.library.assets, exportNames: snapshot.exportNames),
            normalizedLegacyLocations: normalizedLegacyLocations
        )
    }

    nonisolated private static func makeDerivedState(
        assets: [AssetItem],
        exportNames: [String: String]
    ) -> AssetDerivedState {
        let index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        var total = 0, approved = 0, pending = 0, redo = 0, missing = 0
        var counts = Dictionary(uniqueKeysWithValues: SavedView.allCases.map { ($0, 0) })
        var views = Dictionary(uniqueKeysWithValues: SavedView.allCases.map { ($0, [AssetItem]()) })
        var active: [AssetItem] = []
        var trashed: [AssetItem] = []
        var export: [AssetItem] = []
        var nextTagCounts: [String: Int] = [:]
        active.reserveCapacity(assets.count)
        trashed.reserveCapacity(min(assets.count, 100))
        for asset in assets {
            for view in SavedView.allCases where view != .exportLibrary && view.includes(asset) {
                counts[view, default: 0] += 1
                views[view, default: []].append(asset)
            }
            guard asset.deletedAt == nil else { trashed.append(asset); continue }
            active.append(asset)
            for tag in asset.normalizedTags { nextTagCounts[tag, default: 0] += 1 }
            if exportNames[asset.id] != nil { export.append(asset) }
            total += 1
            if asset.decision == .confirmed { approved += 1 }
            if asset.decision == .pending { pending += 1 }
            if asset.qaResult == .repair || asset.productionStatus == .repairing { redo += 1 }
            if asset.decision == .rejected { missing += 1 }
        }
        counts[.exportLibrary] = export.count
        views[.exportLibrary] = export
        return AssetDerivedState(
            assetIndex: index,
            activeAssets: active,
            trashedAssets: trashed,
            exportAssets: export,
            viewAssets: views,
            viewCounts: counts,
            tagCounts: nextTagCounts,
            total: total,
            approved: approved,
            pending: pending,
            redo: redo,
            missing: missing
        )
    }

    private func applyDerivedState(_ state: AssetDerivedState) {
        assetIndex = state.assetIndex
        cachedActiveAssets = state.activeAssets
        cachedTrashedAssets = state.trashedAssets
        cachedExportAssets = state.exportAssets
        cachedViewAssets = state.viewAssets
        cachedCounts = (state.total, state.approved, state.pending, state.redo, state.missing)
        viewCounts = state.viewCounts
        tagCounts = state.tagCounts
        markContentChanged()
    }

    /// Name, note and inspector-only edits should not cause a full library filter/count pass.
    /// Only fields that can move an item between sidebar views or change a metric rebuild it.
    private func affectsDerivedState(_ before: AssetItem, _ after: AssetItem) -> Bool {
        before.type != after.type ||
        before.category != after.category ||
        before.episodes != after.episodes ||
        before.decision != after.decision ||
        before.qaResult != after.qaResult ||
        before.productionStatus != after.productionStatus ||
        before.sourceMissing != after.sourceMissing ||
        before.normalizedTags != after.normalizedTags ||
        before.starRating != after.starRating ||
        before.isMaster != after.isMaster ||
        before.lastUsedAt != after.lastUsedAt ||
        before.deletedAt != after.deletedAt
    }

    private func replaceCachedAsset(_ asset: AssetItem) {
        func replace(_ values: inout [AssetItem]) {
            guard let index = values.firstIndex(where: { $0.id == asset.id }) else { return }
            values[index] = asset
        }
        replace(&cachedActiveAssets)
        replace(&cachedTrashedAssets)
        replace(&cachedExportAssets)
        for view in Array(cachedViewAssets.keys) {
            guard var values = cachedViewAssets[view] else { continue }
            replace(&values)
            cachedViewAssets[view] = values
        }
        markContentChanged()
    }

    private func markContentChanged() {
        invalidateFolderQueries()
        contentRevision &+= 1
        cachedSearchView = ""
        cachedSearchQuery = ""
        cachedSearchFilter = AssetFilter()
        cachedSearchSort = AssetSortConfiguration()
        cachedSearchRevision = .max
        cachedSearchAssets = []
    }

    private func cache(snapshot: ProjectSnapshot, projectID: String) {
        snapshotCache[projectID] = snapshot
        snapshotCacheOrder.removeAll { $0 == projectID }
        snapshotCacheOrder.append(projectID)
        while snapshotCacheOrder.count > 3 {
            snapshotCache.removeValue(forKey: snapshotCacheOrder.removeFirst())
        }
    }

    private var nextAssetSequence: Int {
        (assets.compactMap { $0.id.hasPrefix("ASSET-") ? Int($0.id.dropFirst(6)) : nil }.max() ?? 0) + 1
    }

    nonisolated private static func loadLegacyJSON(at url: URL) -> LibraryData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryData.self, from: data)
    }

    private func backupLegacyJSON() {
        let backup = rootURL.appendingPathComponent("library.pre-sqlite-backup.json")
        guard !fileManager.fileExists(atPath: backup.path), fileManager.fileExists(atPath: legacyDataURL.path) else { return }
        try? fileManager.copyItem(at: legacyDataURL, to: backup)
    }

    @discardableResult
    private func persistPendingManifest(_ items: [PendingImportItem], project: ProjectRecord) async -> Bool {
        pendingManifestRevision &+= 1
        return await pendingManifestWriter.write(
            items: items, root: Self.pendingManifestSupportRoot(project: project), directoryName: Self.pendingManifestSupportDirectoryName,
            manifestName: Self.pendingManifestName, revision: pendingManifestRevision
        )
    }

    nonisolated private static func loadPendingManifest(project: ProjectRecord, legacyRoot: URL) -> [PendingImportItem] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func decodedItems(in directory: URL) -> [PendingImportItem] {
            let manifest = directory.appendingPathComponent(pendingManifestName)
            guard let data = try? Data(contentsOf: manifest),
                  let decoded = try? decoder.decode([PendingImportItem].self, from: data) else { return [] }
            return decoded.filter { FileManager.default.fileExists(atPath: $0.stagedPath) }
        }

        let supportDirectory = pendingManifestSupportRoot(project: project)
            .appendingPathComponent(pendingManifestSupportDirectoryName, isDirectory: true)
        var items = decodedItems(in: supportDirectory)
        let journalItems = PendingImportJournalWriter.load(from: pendingImportJournalURL(project: project))
        var restoredIdentities = Set(items.map(\.sourceIdentity))
        items.append(contentsOf: journalItems.filter { restoredIdentities.insert($0.sourceIdentity).inserted })

        // Read legacy project-root state without recreating that directory.
        let legacyDirectory = legacyRoot.appendingPathComponent(pendingDirectoryName, isDirectory: true)
        let knownIDs = Set(items.map(\.id))
        items.append(contentsOf: decodedItems(in: legacyDirectory).filter { !knownIDs.contains($0.id) })

        // Recover only historical software copies that still physically exist.
        // The directory is never created by this read path.
        let knownPaths = Set(items.map { URL(fileURLWithPath: $0.stagedPath).standardizedFileURL.path })
        for descriptor in scanFolder(legacyDirectory) where !knownPaths.contains(descriptor.url.standardizedFileURL.path) {
            let classification = FilenameAssetClassifier.classify(path: descriptor.url.path)
            items.append(PendingImportItem(
                id: UUID().uuidString, stagedPath: descriptor.url.path,
                originalSourcePath: descriptor.url.path, originalFilename: descriptor.url.lastPathComponent,
                sourceFileID: descriptor.fileID, sourceFileSize: descriptor.fileSize,
                sourceCreatedAt: descriptor.createdAt,
                sourceModifiedAt: descriptor.modifiedAt, pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight, suggestedType: classification.type,
                category: classification.category, createdAt: Date(),
                filenameClassificationEvidence: classification.evidence
            ))
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    nonisolated private static func pendingImportJournalURL(project: ProjectRecord) -> URL {
        pendingManifestSupportRoot(project: project)
            .appendingPathComponent(pendingManifestSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(".assetframe-import-journal.ndjson")
    }

    nonisolated private static func loadDuplicateImportQueue(project: ProjectRecord) -> [DuplicateImportCandidate] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: duplicateImportQueueURL(project: project)),
              let candidates = try? decoder.decode([DuplicateImportCandidate].self, from: data) else { return [] }
        var identities = Set<String>()
        return candidates.filter { identities.insert($0.queueIdentity).inserted }
    }

    nonisolated private static func duplicateImportQueueURL(project: ProjectRecord) -> URL {
        pendingManifestSupportRoot(project: project)
            .appendingPathComponent(pendingManifestSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(duplicateImportQueueName)
    }

    nonisolated private static func pendingManifestSupportRoot(project: ProjectRecord) -> URL {
        URL(fileURLWithPath: project.databasePath).deletingLastPathComponent()
    }

    nonisolated private static func importIdentity(_ asset: AssetItem) -> String {
        sourceIdentity(
            fileID: asset.importSourceFileID ?? asset.sourceFileID ?? "",
            fileSize: asset.importSourceFileSize ?? asset.sourceFileSize ?? 0,
            modifiedAt: asset.importSourceModifiedAt ?? asset.sourceModifiedAt,
            path: asset.imagePath
        )
    }

    nonisolated private static func sourceIdentity(fileID: String, fileSize: Int64, modifiedAt: Date?, path: String) -> String {
        let modifiedSecond = modifiedAt.map { Int64($0.timeIntervalSince1970) } ?? 0
        if !fileID.isEmpty { return "id:\(fileID)|\(fileSize)|\(modifiedSecond)" }
        return "path:\(URL(fileURLWithPath: path).standardizedFileURL.path)|\(fileSize)|\(modifiedSecond)"
    }

    nonisolated private static func prepareStaging(
        urls: [URL], projectRoot: URL, knownIdentities: Set<String>,
        jobID: UUID, kind: ImportJobKind, localFolder: LocalFolderSource?,
        knownContentReferences: [DuplicateContentReference], timing: ImportTiming,
        progress: @escaping @Sendable (ImportProgressState) async -> Void,
        checkpoint: @escaping @Sendable ([PendingImportItem]) async throws -> Void
    ) async -> PendingStageResult {
        let scanner = ImportDirectoryScanner(urls: urls) { url in
            isManagedPath(url.standardizedFileURL.path, projectRoot: projectRoot)
        }
        var items: [PendingImportItem] = []
        var identities = knownIdentities
        var skipped = 0
        var processed = 0
        var total = 0
        var paths = Set<String>([""])
        var failure: String?
        var finished = false
        var first = true
        var lastProgress = Date.distantPast
        while !Task.isCancelled, !finished {
            let scanStart = Date.now
            let batch = await scanner.next(first: first)
            timing.record("scan", since: scanStart)
            finished = batch.finished
            for directory in batch.directories {
                if let folder = localFolder,
                   let relative = relativePath(of: directory, root: URL(fileURLWithPath: folder.rootPath)) {
                    paths.insert(relative)
                }
            }
            let candidates = batch.files.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            total += candidates.count
            let registrationStart = Date.now
            var staged: [PendingImportItem] = []
            for url in candidates {
                if Task.isCancelled { break }
                let descriptor = describe(url: url, root: projectRoot, includeDimensions: false)
                let identity = sourceIdentity(fileID: descriptor.fileID, fileSize: descriptor.fileSize,
                    modifiedAt: descriptor.modifiedAt, path: descriptor.url.path)
                if identities.insert(identity).inserted {
                    staged.append(pendingImportItem(from: descriptor, localFolder: localFolder))
                } else { skipped += 1 }
                processed += 1
            }
            timing.record("lightweight_registration", since: registrationStart)
            do {
                if !staged.isEmpty { try await checkpoint(staged) }
                items.append(contentsOf: staged)
            } catch {
                failure = "保存失败，已保留断点：\(error.localizedDescription)"
                break
            }
            if !batch.errors.isEmpty { failure = batch.errors.joined(separator: "\n") }
            if first || finished || Date.now.timeIntervalSince(lastProgress) >= 0.12 {
                lastProgress = .now
                await progress(ImportProgressState(
                    id: jobID, phase: finished ? .importing : .scanning,
                    total: total, processed: processed, imported: items.count, skipped: skipped,
                    currentFilename: "已登记 \(items.count) 项，可立即浏览", kind: kind
                ))
            }
            first = false
        }
        return PendingStageResult(items: items, skipped: skipped, duplicatePaths: [], duplicateCandidates: [],
            sourceFolderID: localFolder?.id, directoryPaths: paths.sorted(), total: total, processed: processed,
            wasCancelled: Task.isCancelled, usedFastIndex: true, failure: failure)
    }

    nonisolated private static func enrichImageDimensions(_ descriptor: SourceDescriptor) -> SourceDescriptor? {
        guard !Task.isCancelled else { return nil }
        var result = descriptor
        let dimensions = imageDimensions(at: descriptor.url)
        guard !Task.isCancelled else { return nil }
        result.pixelWidth = dimensions.width
        result.pixelHeight = dimensions.height
        return result
    }

    nonisolated private static func pendingImportItem(
        from descriptor: SourceDescriptor,
        localFolder: LocalFolderSource?
    ) -> PendingImportItem {
        let classification = FilenameAssetClassifier.classify(path: descriptor.url.path)
        return PendingImportItem(
            id: UUID().uuidString, stagedPath: descriptor.url.path,
            originalSourcePath: descriptor.url.path, originalFilename: descriptor.url.lastPathComponent,
            sourceFileID: descriptor.fileID, sourceFileSize: descriptor.fileSize,
            sourceCreatedAt: descriptor.createdAt,
            sourceModifiedAt: descriptor.modifiedAt, pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight, suggestedType: classification.type,
            category: classification.category, createdAt: Date(),
            sourceFolderID: localFolder?.id,
            sourceRelativePath: localFolder.map {
                relativePath(of: descriptor.url, root: URL(fileURLWithPath: $0.rootPath))
            } ?? descriptor.relativePath,
            filenameClassificationEvidence: classification.evidence
        )
    }

    nonisolated private static func exactDuplicatePath(
        for descriptor: SourceDescriptor,
        candidates: [DuplicateContentReference],
        quickHashCache: inout [String: String],
        hashCache: inout [String: String]
    ) -> String? {
        guard descriptor.fileSize > 0, !candidates.isEmpty,
              let incomingQuickHash = quickFileFingerprint(
                atPath: descriptor.url.path,
                fileSize: descriptor.fileSize,
                cache: &quickHashCache
              ) else { return nil }
        var incomingHash: String?
        for candidate in candidates where candidate.path != descriptor.url.path {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let candidateQuickHash = quickFileFingerprint(
                    atPath: candidate.path,
                    fileSize: candidate.fileSize,
                    cache: &quickHashCache
                  ), candidateQuickHash == incomingQuickHash else { continue }
            if incomingHash == nil {
                incomingHash = fileSHA256(atPath: descriptor.url.path, cache: &hashCache)
            }
            guard let incomingHash,
                  let candidateHash = fileSHA256(atPath: candidate.path, cache: &hashCache) else { continue }
            if candidateHash == incomingHash { return candidate.path }
        }
        return nil
    }

    /// A cheap prefilter only. Equality still requires the complete SHA256 below.
    nonisolated private static func quickFileFingerprint(
        atPath path: String,
        fileSize: Int64,
        cache: inout [String: String]
    ) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let cached = cache[standardized] { return cached }
        guard !Task.isCancelled else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: standardized))
            defer { try? handle.close() }
            let sampleSize = 64 * 1_024
            var hasher = SHA256()
            hasher.update(data: Data("\(fileSize)|".utf8))
            if let head = try handle.read(upToCount: sampleSize) { hasher.update(data: head) }
            if fileSize > Int64(sampleSize) {
                try handle.seek(toOffset: UInt64(max(0, fileSize - Int64(sampleSize))))
                if let tail = try handle.read(upToCount: sampleSize) { hasher.update(data: tail) }
            }
            guard !Task.isCancelled else { return nil }
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            cache[standardized] = fingerprint
            return fingerprint
        } catch {
            return nil
        }
    }

    nonisolated private static func fileSHA256(atPath path: String, cache: inout [String: String]) -> String? {
        ImportContentReadGate.hashLock.lock()
        defer { ImportContentReadGate.hashLock.unlock() }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let cached = cache[standardized] { return cached }
        guard !Task.isCancelled else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: standardized))
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                guard !Task.isCancelled else { return nil }
                hasher.update(data: chunk)
            }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            cache[standardized] = hash
            return hash
        } catch {
            return nil
        }
    }

    nonisolated private static func performPendingConfirmation(
        items: [PendingImportItem], projectID: String, projectRoot: URL,
        startingAt: Int, jobID: UUID,
        progress: @escaping @Sendable (ImportProgressState) async -> Void
    ) async -> PendingConfirmResult {
        var imported: [AssetItem] = []
        var completedIDs = Set<String>()
        var failed = 0
        for (offset, item) in items.enumerated() {
            if Task.isCancelled { break }
            let original = URL(fileURLWithPath: item.originalSourcePath).standardizedFileURL
            let staged = URL(fileURLWithPath: item.stagedPath).standardizedFileURL
            let source = FileManager.default.fileExists(atPath: original.path) ? original : staged
            do {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let descriptor = describe(url: source, root: projectRoot)
                var asset = makeAsset(descriptor: descriptor, projectID: projectID, sequence: startingAt + imported.count)
                asset.name = item.name
                asset.originalFilename = item.originalFilename
                asset.type = item.suggestedType
                asset.category = item.category
                asset.exportName = item.name
                asset.sourceFolderID = item.sourceFolderID
                asset.sourceOriginalPath = source.path
                if item.sourceFolderID != nil {
                    asset.sourceRelativePath = item.sourceRelativePath
                }
                asset.importSourceFileID = descriptor.fileID
                asset.importSourceFileSize = descriptor.fileSize
                asset.importSourceModifiedAt = descriptor.modifiedAt
                asset.purpose = item.suggestedPurpose ?? asset.purpose
                asset.generationProvenance = item.generationProvenance
                if let provenance = item.generationProvenance {
                    asset.generationPlatform = provenance.generationPlatform
                    asset.promptSource = "Codex任务：\(provenance.taskTitle) · 批次 \(provenance.batchID)"
                }
                asset.tags = item.normalizedManualTags
                imported.append(asset)
                completedIDs.insert(item.id)
                // Once a legacy pending item has been registered against its
                // still-existing original, remove only the obsolete managed
                // staging copy so orphan recovery cannot import it again.
                if staged.path != source.path,
                   isManagedPath(staged.path, projectRoot: projectRoot) {
                    try? FileManager.default.removeItem(at: staged)
                }
            } catch {
                failed += 1
            }
            await progress(ImportProgressState(
                id: jobID, phase: .importing, total: items.count, processed: offset + 1,
                imported: imported.count, skipped: failed, currentFilename: item.originalFilename, kind: .confirmImport
            ))
        }
        return PendingConfirmResult(assets: imported, completedIDs: completedIDs, failed: failed)
    }

    nonisolated private static func inferredType(filename: String) -> AssetType {
        FilenameAssetClassifier.classify(path: filename).type
    }

    nonisolated private static func inferredCategory(filename: String, type: AssetType) -> AssetCategory {
        let classified = FilenameAssetClassifier.classify(path: filename)
        if classified.category == .common { return .common }
        return type == .unclassified ? .pending : .project
    }

    nonisolated private static func formalFolderName(for item: PendingImportItem) -> String {
        if item.category == .common { return "通用资产" }
        switch item.suggestedType {
        case .person, .creature: return "人物资产"
        case .venue, .scene: return "场景资产"
        case .unclassified: return "待分类"
        default: return "道具资产"
        }
    }

    nonisolated private static func managedFolderName(for asset: AssetItem) -> String {
        if asset.category == .common { return "通用资产" }
        return managedTypeFolderName(for: asset)
    }

    nonisolated private static func managedTypeFolderName(for asset: AssetItem) -> String {
        switch asset.type {
        case .person, .creature: return "人物资产"
        case .venue, .scene: return "场景资产"
        case .unclassified: return "待分类"
        default: return "道具资产"
        }
    }

    nonisolated private static func fiveStarLibraryRoot(project: ProjectRecord, projectRoot: URL, ssdRoot: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: ssdRoot.path) else { return nil }
        let projectPath = projectRoot.standardizedFileURL.path
        if projectPath == ssdRoot.path || projectPath.hasPrefix(ssdRoot.path + "/") {
            return projectRoot.appendingPathComponent(libraryDirectoryName, isDirectory: true)
        }
        let safeName = sanitize(project.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let projectDirectoryName = "\(safeName.isEmpty ? "未命名项目" : safeName)_\(project.id.prefix(8))"
        return ssdRoot
            .appendingPathComponent("向量时刻资产库", isDirectory: true)
            .appendingPathComponent(projectDirectoryName, isDirectory: true)
            .appendingPathComponent(libraryDirectoryName, isDirectory: true)
    }

    nonisolated private static func enrichLegacy(_ library: LibraryData, project: ProjectRecord, root: URL) -> LibraryData {
        var copy = library
        for index in copy.assets.indices {
            copy.assets[index].projectID = project.id
            let url = URL(fileURLWithPath: copy.assets[index].imagePath)
            copy.assets[index].sourceRelativePath = Self.relativePath(of: url, root: root)
            let descriptor = Self.describe(url: url, root: root)
            copy.assets[index].sourceFileID = descriptor.fileID
            copy.assets[index].sourceFileSize = descriptor.fileSize
            copy.assets[index].sourceCreatedAt = descriptor.createdAt
            copy.assets[index].sourceModifiedAt = descriptor.modifiedAt
            copy.assets[index].pixelWidth = descriptor.pixelWidth
            copy.assets[index].pixelHeight = descriptor.pixelHeight
            copy.assets[index].isSourceMissing = !FileManager.default.fileExists(atPath: url.path)
            copy.assets[index].exportName = copy.assets[index].exportName ?? copy.assets[index].name
        }
        return copy
    }

    nonisolated private static func reconcile(existing: [AssetItem], descriptors: [SourceDescriptor], projectID: String, root: URL, startingAt: Int) -> (assets: [AssetItem], added: Int) {
        var result = existing
        var indexByFileID: [String: Int] = [:]
        var indexByPath: [String: Int] = [:]
        for (index, asset) in result.enumerated() {
            if let fileID = asset.sourceFileID, !fileID.isEmpty { indexByFileID[fileID] = index }
            indexByPath[URL(fileURLWithPath: asset.imagePath).standardizedFileURL.path] = index
        }
        var seen = Set<Int>()
        var next = startingAt
        var added = 0
        for descriptor in descriptors {
            let path = descriptor.url.standardizedFileURL.path
            if let index = indexByFileID[descriptor.fileID] ?? indexByPath[path] {
                result[index].imagePath = path
                result[index].sourceRelativePath = descriptor.relativePath
                result[index].sourceFileID = descriptor.fileID
                result[index].sourceFileSize = descriptor.fileSize
                result[index].sourceCreatedAt = descriptor.createdAt
                result[index].sourceModifiedAt = descriptor.modifiedAt
                result[index].pixelWidth = descriptor.pixelWidth
                result[index].pixelHeight = descriptor.pixelHeight
                result[index].thumbnailKey = nil
                result[index].isSourceMissing = false
                seen.insert(index)
            } else {
                result.append(makeAsset(descriptor: descriptor, projectID: projectID, sequence: next))
                seen.insert(result.count - 1); next += 1; added += 1
            }
        }
        for index in result.indices where !seen.contains(index) {
            result[index].isSourceMissing = !FileManager.default.fileExists(atPath: result[index].imagePath)
        }
        return (result, added)
    }

    nonisolated private static func prepareReferences(
        urls: [URL], root: URL, projectID: String, knownPaths: Set<String>, startingAt: Int, jobID: UUID,
        progress: @escaping @Sendable (ImportProgressState) async -> Void
    ) async -> ImportResult {
        let descriptors = urls.flatMap { url -> [SourceDescriptor] in
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { return scanFolder(url) }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return [] }
            return [describe(url: url, root: root)]
        }
        await progress(ImportProgressState(id: jobID, phase: .importing, total: descriptors.count, processed: 0, imported: 0, skipped: 0, currentFilename: descriptors.first?.url.lastPathComponent ?? "没有找到支持的图片"))
        var imported: [AssetItem] = []
        var skipped = 0
        var paths = knownPaths
        for (offset, descriptor) in descriptors.enumerated() {
            let path = descriptor.url.standardizedFileURL.path
            if paths.contains(path) { skipped += 1 }
            else { imported.append(makeAsset(descriptor: descriptor, projectID: projectID, sequence: startingAt + imported.count)); paths.insert(path) }
            await progress(ImportProgressState(id: jobID, phase: .importing, total: descriptors.count, processed: offset + 1, imported: imported.count, skipped: skipped, currentFilename: descriptor.url.lastPathComponent))
        }
        return ImportResult(assets: imported, skipped: skipped)
    }

    nonisolated private static func scanFolder(
        _ root: URL,
        excludingManagedDirectoriesUnder projectRoot: URL? = nil,
        includeDimensions: Bool = true
    ) -> [SourceDescriptor] {
        if let projectRoot, isManagedPath(root.standardizedFileURL.path, projectRoot: projectRoot) { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .fileResourceIdentifierKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var descriptors: [SourceDescriptor] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if let projectRoot, isManagedPath(url.standardizedFileURL.path, projectRoot: projectRoot) {
                enumerator.skipDescendants()
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            descriptors.append(describe(url: url, root: root, includeDimensions: includeDimensions))
        }
        return descriptors
    }

    /// 保留目录节点（包括空目录），供侧栏按本地结构完整镜像。
    nonisolated private static func localDirectoryPaths(
        at root: URL,
        excludingManagedDirectoriesUnder projectRoot: URL? = nil
    ) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [""] }
        var paths = [""]
        while let url = enumerator.nextObject() as? URL {
            if let projectRoot, isManagedPath(url.standardizedFileURL.path, projectRoot: projectRoot) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
                  values.isDirectory == true,
                  values.isHidden != true,
                  let relative = relativePath(of: url, root: root),
                  !relative.isEmpty else { continue }
            paths.append(relative)
        }
        return Array(Set(paths)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func refreshSourceMetadata(_ current: [AssetItem]) async -> [AssetItem] {
        var refreshed: [AssetItem] = []
        refreshed.reserveCapacity(current.count)
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        for (offset, asset) in current.enumerated() {
            if Task.isCancelled { return current }
            var copy = asset
            let url = URL(fileURLWithPath: asset.imagePath)
            guard let values = try? url.resourceValues(forKeys: keys) else {
                copy.isSourceMissing = true
                refreshed.append(copy)
                continue
            }

            let fileSize = Int64(values.fileSize ?? 0)
            let createdAt = values.creationDate
            let modifiedAt = values.contentModificationDate
            let fileID = values.fileResourceIdentifier.map { String(describing: $0) } ?? url.standardizedFileURL.path
            let sourceChanged = copy.sourceFileSize != fileSize || copy.sourceModifiedAt != modifiedAt
            copy.isSourceMissing = false
            copy.sourceFileID = fileID
            copy.sourceFileSize = fileSize
            copy.sourceCreatedAt = createdAt
            copy.sourceModifiedAt = modifiedAt

            // Reading pixel properties touches image contents. Skip it when the
            // file is unchanged and dimensions are already indexed.
            if sourceChanged || copy.pixelWidth == nil || copy.pixelHeight == nil {
                let dimensions = imageDimensions(at: url)
                copy.pixelWidth = dimensions.width
                copy.pixelHeight = dimensions.height
                if sourceChanged { copy.thumbnailKey = nil }
            }
            refreshed.append(copy)
            if offset.isMultiple(of: 128) { await Task.yield() }
        }
        return refreshed
    }

    nonisolated private static func describe(url: URL, root: URL, includeDimensions: Bool = true) -> SourceDescriptor {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let dimensions: (width: Int?, height: Int?) = includeDimensions
            ? imageDimensions(at: url)
            : (width: nil, height: nil)
        return SourceDescriptor(
            url: url.standardizedFileURL,
            relativePath: relativePath(of: url, root: root),
            fileID: values?.fileResourceIdentifier.map { String(describing: $0) } ?? url.standardizedFileURL.path,
            fileSize: Int64(values?.fileSize ?? 0),
            createdAt: values?.creationDate,
            modifiedAt: values?.contentModificationDate,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height
        )
    }

    nonisolated private static func imageDimensions(at url: URL) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (width, height)
    }

    nonisolated private static func relativePath(of url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return path == rootPath ? "" : String(path.dropFirst(rootPath.count + 1))
    }

    nonisolated private static func makeAsset(descriptor: SourceDescriptor, projectID: String, sequence: Int) -> AssetItem {
        AssetItem(
            id: "ASSET-\(String(format: "%03d", sequence))", name: descriptor.url.deletingPathExtension().lastPathComponent,
            type: .unclassified, imagePath: descriptor.url.path, originalFilename: descriptor.url.lastPathComponent,
            decision: .pending, note: "", reuse: .b, project: "", episodes: [], candidatePlan: .none,
            version: "v01", purpose: .pending, category: .pending, qaResult: .pending, productionStatus: .pendingAcceptance,
            assetDescription: "", repairReason: "", fingerprint: "", shapeState: "", promptSource: "", generationPlatform: "",
            position: CanvasPoint(x: 510 + CGFloat((sequence - 1) % 3) * 230, y: 80 + CGFloat((sequence - 1) / 3) * 205), createdAt: Date(),
            projectID: projectID, sourceRelativePath: descriptor.relativePath, sourceFileID: descriptor.fileID,
            sourceFileSize: descriptor.fileSize, sourceCreatedAt: descriptor.createdAt,
            sourceModifiedAt: descriptor.modifiedAt, isSourceMissing: false,
            exportName: descriptor.url.deletingPathExtension().lastPathComponent,
            pixelWidth: descriptor.pixelWidth, pixelHeight: descriptor.pixelHeight
        )
    }

    nonisolated private static func performExport(
        assets: [AssetItem], exportNames: [String: String], project: ProjectRecord, destination: URL, jobID: UUID,
        progress: @escaping @Sendable (ExportProgressState) async -> Void
    ) async -> ExportProgressState {
        let sourceByAssetID = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in bestAvailableSource(for: asset).map { (asset.id, $0) } })
        let missing = assets.filter { sourceByAssetID[$0.id] == nil }
        let invalid = assets.filter { $0.type == .unclassified || (exportNames[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !missing.isEmpty || !invalid.isEmpty {
            let message = ([missing.isEmpty ? nil : "\(missing.count) 项源文件缺失", invalid.isEmpty ? nil : "\(invalid.count) 项未分类或名称为空"].compactMap { $0 }).joined(separator: "；")
            return ExportProgressState(id: jobID, phase: .failed, total: assets.count, processed: 0, succeeded: 0, failed: missing.count + invalid.count, currentFilename: "", resultPath: nil, message: message)
        }
        await progress(ExportProgressState(id: jobID, phase: .exporting, total: assets.count, processed: 0, succeeded: 0, failed: 0, currentFilename: "准备导出目录…", resultPath: nil, message: ""))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd_HHmm"
        let baseName = "\(sanitize(project.name))_资产导出_\(formatter.string(from: Date()))"
        let finalURL = uniqueDirectory(baseName: baseName, parent: destination)
        let staging = destination.appendingPathComponent(".\(UUID().uuidString).asset-export", isDirectory: true)
        let folders = ["人物资产", "道具资产", "场景资产", "通用资产"]
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for folder in folders { try FileManager.default.createDirectory(at: staging.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true) }
            var succeeded = 0
            var manifestNames: [String: String] = [:]
            var manifestSources: [String: AssetSourceVersion] = [:]
            var usedNames: [String: Int] = [:]
            for (offset, asset) in assets.enumerated() {
                guard let source = sourceByAssetID[asset.id] else { continue }
                let folder = exportFolder(for: asset)
                let ext = URL(fileURLWithPath: source.path).pathExtension.lowercased()
                let base = sanitize("\(asset.type.rawValue)_\(exportNames[asset.id] ?? asset.name)_\(asset.reuse.rawValue)_\(asset.version)")
                let key = "\(folder)/\(base).\(ext)"
                let count = usedNames[key, default: 0] + 1; usedNames[key] = count
                let filename = count == 1 ? "\(base).\(ext)" : "\(base)_\(String(format: "%02d", count)).\(ext)"
                let target = staging.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(filename)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: target)
                manifestNames[asset.id] = "\(folder)/\(filename)"
                manifestSources[asset.id] = source
                succeeded += 1
                await progress(ExportProgressState(id: jobID, phase: .exporting, total: assets.count, processed: offset + 1, succeeded: succeeded, failed: 0, currentFilename: filename, resultPath: nil, message: ""))
            }
            let manifest = csvManifest(assets: assets, exportedNames: manifestNames, exportedSources: manifestSources)
            try manifest.write(to: staging.appendingPathComponent("资产清单.csv"), atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: staging, to: finalURL)
            return ExportProgressState(id: jobID, phase: .completed, total: assets.count, processed: assets.count, succeeded: succeeded, failed: 0, currentFilename: "导出完成", resultPath: finalURL.path, message: "已生成四类资产文件夹和资产清单.csv")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return ExportProgressState(id: jobID, phase: .failed, total: assets.count, processed: 0, succeeded: 0, failed: 1, currentFilename: "", resultPath: nil, message: error.localizedDescription)
        }
    }

    nonisolated private static func exportFolder(for asset: AssetItem) -> String {
        if asset.category == .common { return "通用资产" }
        switch asset.type {
        case .person, .creature: return "人物资产"
        case .venue, .scene: return "场景资产"
        default: return "道具资产"
        }
    }

    nonisolated static func bestAvailableSource(for asset: AssetItem) -> AssetSourceVersion? {
        asset.allSourceVersions
            .filter { !$0.path.isEmpty && FileManager.default.fileExists(atPath: $0.path) }
            .max { lhs, rhs in
                if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount < rhs.pixelCount }
                return (lhs.fileSize ?? 0) < (rhs.fileSize ?? 0)
            }
    }

    nonisolated private static func uniqueDirectory(baseName: String, parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = parent.appendingPathComponent("\(baseName)_\(String(format: "%02d", index))", isDirectory: true); index += 1 }
        return candidate
    }

    nonisolated private static func uniqueFile(named filename: String, in directory: URL) -> URL {
        let original = URL(fileURLWithPath: filename)
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = "_\(String(format: "%02d", index))"
            let nextName = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }

    nonisolated private static func isManagedPath(_ path: String, projectRoot: URL) -> Bool {
        let rootPath = projectRoot.standardizedFileURL.path
        let pending = rootPath + "/" + pendingDirectoryName
        let library = rootPath + "/" + libraryDirectoryName
        let codexInbox = rootPath + "/" + CodexGenerationIntake.inboxDirectoryName
        return path == pending || path.hasPrefix(pending + "/")
            || path == library || path.hasPrefix(library + "/")
            || path == codexInbox || path.hasPrefix(codexInbox + "/")
    }

    nonisolated private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let result = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? "未命名资产" : result).prefix(120))
    }

    nonisolated fileprivate static func csvManifest(assets: [AssetItem], exportedNames: [String: String], exportedSources: [String: AssetSourceVersion]) -> String {
        let header = "资产编号,候选名称,类型,导出文件,输出原图路径,像素尺寸,清晰度,用户决策,等级,五星评分,标签,精选母版,版本,资产归类,源文件状态,来源网址"
        let rows = assets.map { asset in
            let source = exportedSources[asset.id] ?? asset.currentSourceVersion
            return [asset.id, asset.name, asset.type.rawValue, exportedNames[asset.id] ?? "", source.path, source.dimensionText, source.resolutionLabel, asset.decision.rawValue, asset.reuse.rawValue, "\(asset.starRating)", asset.normalizedTags.joined(separator: ";"), asset.isMaster ? "是" : "否", asset.version, asset.category.rawValue, bestAvailableSource(for: asset) == nil ? "源文件缺失" : "正常", asset.sourceURL ?? ""]
                .map(csvEscape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    /// 剧本拆解只允许人物/场景/道具三类；生物和场地分别兼容人物、场景。
    nonisolated static func scriptAssetType(_ requested: AssetType, matches actual: AssetType) -> Bool {
        if requested == actual { return true }
        switch (requested, actual) {
        case (.person, .creature), (.creature, .person), (.scene, .venue), (.venue, .scene): return true
        default: return false
        }
    }

    nonisolated static func scriptAssetChecklistCSV(
        record: ScriptExtractionRecord, variants: [AssetVariantRecord], entities: [AssetEntityRecord],
        assets: [AssetItem], project: ProjectRecord
    ) -> String {
        let entityByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        let variantByID = Dictionary(uniqueKeysWithValues: variants.map { ($0.id, $0) })
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let header = "项目,来源文件,需要使用,资产类型,剧本资产名称,剧本形态,出现位置,原文依据,备注,匹配状态,正式调用编号,正式资产,导出建议"
        let rows = record.candidates.compactMap { candidate -> String? in
            guard candidate.isRequiredForProduction else { return nil }
            let variant = candidate.linkedVariantID.flatMap { variantByID[$0] }
            let entity = variant.flatMap { entityByID[$0.entityID] }
            let main = variant.flatMap { $0.mainAssetID ?? Optional($0.coverAssetID) }.flatMap { assetByID[$0] }
            let status = candidate.effectiveLinkState.rawValue
            let export = main.map { "\(variant?.effectiveCallCode ?? $0.id)_v\(String(format: "%02d", variant?.version ?? 1))_MAIN.png" } ?? ""
            return [project.name, record.sourceName, "是", candidate.type.rawValue, candidate.name, candidate.effectiveFormName,
                    candidate.appearances.joined(separator: "；"), candidate.evidence, candidate.note, status,
                    variant?.effectiveCallCode ?? "", entity.map { "\($0.name) · \(variant?.effectiveVariantName ?? "")" } ?? "", export]
                .map(csvEscape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    nonisolated private static func csvEscape(_ value: String) -> String { value.contains(",") || value.contains("\n") || value.contains("\"") ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" : value }
    nonisolated private static let pendingDirectoryName = "00_向量时刻待导入"
    nonisolated private static let pendingManifestSupportDirectoryName = "PendingImports"
    nonisolated private static let libraryDirectoryName = "01_向量时刻资产库"
    nonisolated private static let pendingManifestName = ".assetframe-pending.json"
    nonisolated private static let duplicateImportQueueName = ".assetframe-duplicates.json"
    nonisolated private static let supportedExtensions = Set(["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff"])

    func showToast(_ message: String) {
        toast = message
        Task { [weak self] in try? await Task.sleep(for: .seconds(2)); if self?.toast == message { self?.toast = nil } }
    }

}
