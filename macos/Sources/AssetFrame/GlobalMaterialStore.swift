import AppKit
import Combine
import CryptoKit
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct MaterialImportResult: Identifiable, Sendable {
    var id: String = UUID().uuidString
    var path: String
    var message: String
    var outcome: String = "failed"
}

private enum MaterialImportScanEvent: Sendable {
    case file(URL)
    case error(MaterialImportResult)
    case finished(Int)
}

private struct MaterialImportBatchOutcome: Sendable {
    var messages: [MaterialImportResult]
    var sourceIdentities: Set<String>
    var metadata: [String: MaterialMediaMetadata]
    var readCount: Int
    var saveSeconds: Double
    var didSave: Bool
}

@MainActor
final class GlobalMaterialStore: ObservableObject {
    private static var sharedStores: [String: GlobalMaterialStore] = [:]
    static func shared(rootURL: URL? = nil) -> GlobalMaterialStore {
        let key = rootURL?.standardizedFileURL.path ?? "production"
        if let store = sharedStores[key] { return store }
        let store = GlobalMaterialStore(rootURL: rootURL); sharedStores[key] = store; return store
    }
    static func finishBeforeTermination() async {
        for store in sharedStores.values {
            store.cancelImport(); await store.importTask?.value
            await store.managedCopyTask?.value
            _ = await store.saveNow()
        }
    }
    @Published var managedCopyJobs = 0
    var managedCopyTask: Task<Void, Never>?
    let importController = MaterialImportController()
    @Published private(set) var materials: [MaterialRecord] = []
    @Published private(set) var organization = LibraryOrganization()
    @Published private(set) var tagging = MaterialTaggingState()
    private var sessionPaused = false
    var importProjectID: String?
    @Published private(set) var links: [ProjectMaterialLink] = []
    @Published private(set) var presets: [MaterialFilterPreset] = []
    @Published var toast: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isLoading = true
    @Published private(set) var persistenceError: String?
    @Published private(set) var canUndoEdit = false
    @Published private(set) var canRedoEdit = false
    private var undoEdits: [MaterialUndoPatch] = []
    private var redoEdits: [MaterialUndoPatch] = []
    @Published private(set) var revision = 0
    private(set) var queryRevision: UInt64 = 0
    private(set) var usageRevision: UInt64 = 0
    var persistenceCommitCount: UInt64 { commitRevision }
    var undoHistoryCount: Int { undoEdits.count }
    var redoHistoryCount: Int { redoEdits.count }
    private var unpublishedQueryChange = false
    private var previewUsage: [String: Date] = [:]
    private var previewUsageTimer: Task<Void, Never>?
    private(set) var importResults: [MaterialImportResult] {
        get { importController.importResults }
        set { importController.importResults = newValue }
    }
    private(set) var importTotal: Int {
        get { importController.importTotal }
        set { importController.importTotal = newValue }
    }
    @Published private(set) var importProgressVisible = false
    private(set) var importPhase: String {
        get { importController.importPhase }
        set { importController.importPhase = newValue }
    }
    private(set) var importCurrentFile: String {
        get { importController.importCurrentFile }
        set { importController.importCurrentFile = newValue }
    }
    private(set) var importDiscovered: Int {
        get { importController.importDiscovered }
        set { importController.importDiscovered = newValue }
    }
    private(set) var importProcessed: Int {
        get { importController.importProcessed }
        set { importController.importProcessed = newValue }
    }
    private(set) var importRead: Int {
        get { importController.importRead }
        set { importController.importRead = newValue }
    }
    private(set) var importSaveCount: Int {
        get { importController.importSaveCount }
        set { importController.importSaveCount = newValue }
    }
    private(set) var importReadSeconds: Double {
        get { importController.importReadSeconds }
        set { importController.importReadSeconds = newValue }
    }
    private(set) var importSaveSeconds: Double {
        get { importController.importSaveSeconds }
        set { importController.importSaveSeconds = newValue }
    }
    private(set) var importScanCompleted: Bool {
        get { importController.importScanCompleted }
        set { importController.importScanCompleted = newValue }
    }
    private(set) var importAdded: Int {
        get { importController.importAdded }
        set { importController.importAdded = newValue }
    }
    private(set) var importDuplicate: Int {
        get { importController.importDuplicate }
        set { importController.importDuplicate = newValue }
    }
    private(set) var importFailed: Int {
        get { importController.importFailed }
        set { importController.importFailed = newValue }
    }
    private(set) var importSkipped: Int {
        get { importController.importSkipped }
        set { importController.importSkipped = newValue }
    }
    private(set) var importCancelled: Int {
        get { importController.importCancelled }
        set { importController.importCancelled = newValue }
    }
    private(set) var importEstimatedRemainingSeconds: Double? {
        get { importController.importEstimatedRemainingSeconds }
        set { importController.importEstimatedRemainingSeconds = newValue }
    }
    func dismissImportProgress() { if !isImporting { importProgressVisible = false } }
    @Published private(set) var isSaving = false
    let managedSSDURL: URL
    private let database: MaterialDatabase
    private var committedSnapshot: MaterialSnapshot?
    private var commitRevision: UInt64 = 0
    private var publishedCommitRevision: UInt64 = 0
    private var lastPublication = Date.distantPast
    private var importTiming = ImportTiming()
    private var pending: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importPauseRequested = false
    private var readingLinkedFolders = false
    private var enrichmentTask: Task<Void, Never>?
    @Published private(set) var resumableImport: ImportResumeRecord?
    private var resumeURL: URL { database.root.appendingPathComponent("material-import-resume.json") }
    func resumeImport() {
        guard let job = resumableImport else { return }
        importProjectID = job.projectID
        importFiles(job.paths.map(URL.init(fileURLWithPath:)), limitingTo: job.audioOnly ? [.audio] : nil, resuming: job)
    }
    func cancelBackgroundMetadata() { enrichmentTask?.cancel() }
    func waitForBackgroundMetadata() async { await enrichmentTask?.value }
    func waitForImportCompletion() async { await importTask?.value }
    /// Completion of an already-admitted copy must drain while a library pauses.
    func completeManagedCopy(_ id: String, path: String) {
        mutate(changesQuery: false) { snapshot in
            guard let index = snapshot.materials.firstIndex(where: { $0.id == id }) else { return }
            var p = snapshot.materials[index].production ?? MaterialProductionMetadata()
            if !p.managedCopies.contains(path) { p.managedCopies.append(path) }
            snapshot.materials[index].production = p
        }
    }

    // A bounded courtesy pause at batch boundaries, never a lock on the UI.
    private static var lastBrowseInteraction: ContinuousClock.Instant?
    static func noteBrowseInteraction() { lastBrowseInteraction = .now; PreviewCacheBudget.shared.noteInteraction() }
    private static func yieldToBrowsing() async {
        guard let lastBrowseInteraction, lastBrowseInteraction.duration(to: .now) < .milliseconds(180) else { return }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func supplementMetadata() {
        enrichmentTask?.cancel()
        guard !sessionPaused else { return }
        let metadataSnapshot = materials
        enrichmentTask = Task { [weak self] in
            let filterWorker = Task.detached(priority: .utility) {
                metadataSnapshot.filter { $0.sourcePath != nil && $0.mediaMetadata == nil && $0.fingerprint.hasPrefix("source:") }
            }
            let candidates = await withTaskCancellationHandler { await filterWorker.value } onCancel: { filterWorker.cancel() }
            guard !Task.isCancelled, let self, !self.sessionPaused else { return }
            let timing = ImportTiming()
            defer { timing.report("material_background") }
            for chunkStart in stride(from: 0, to: candidates.count, by: 32) {
                await Self.yieldToBrowsing()
                guard !Task.isCancelled, !isImporting else { return }
                let chunk = Array(candidates[chunkStart..<min(chunkStart + 32, candidates.count)])
                let worker = Task.detached(priority: .utility) {
                    var results: [(MaterialRecord, MaterialRecord)] = []
                    for original in chunk {
                        guard !Task.isCancelled else { break }
                        guard let path = original.sourcePath else { continue }
                        let url = URL(fileURLWithPath: path)
                        guard ImportResumeRecord.availableLocally(url),
                              let record = await Self.record(url) else { continue }
                        results.append((original, record))
                    }
                    return results
                }
                let updates = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, !isImporting else { return }
                await mutate { snapshot in
                    for (original, update) in updates {
                        guard let index = snapshot.materials.firstIndex(where: { $0.id == original.id }),
                              snapshot.materials[index].sourcePath == update.sourcePath,
                              snapshot.materials[index].fileSize == update.fileSize,
                              snapshot.materials[index].sourceModifiedAt == update.sourceModifiedAt,
                              snapshot.materials[index].mediaMetadata == nil else { continue }
                        let duplicate = snapshot.materials.first { $0.id != original.id && ($0.contentFingerprint ?? $0.fingerprint) == update.fingerprint }
                        snapshot.materials[index].mediaMetadata = update.mediaMetadata
                        snapshot.materials[index].contentFingerprint = update.fingerprint
                        snapshot.materials[index].duplicateContentOf = duplicate?.id
                    }
                }.value
            }
        }
    }
    var canWrite: Bool { !isLoading && persistenceError == nil }
    var dataRoot: URL { database.root }

    init(rootURL: URL? = nil, managedRoot: URL? = nil, paused: Bool = false) {
        sessionPaused = paused
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        managedSSDURL = managedRoot ?? rootURL?.appendingPathComponent("ManagedFiveStar") ?? URL(fileURLWithPath: "/Volumes/SSD-1TB")
        database = MaterialDatabase(root: rootURL ?? support.appendingPathComponent("AssetFrame", isDirectory: true))
        loading = Task { await reload() }
    }
    func pauseSession() async -> Result<Void, Error> {
        sessionPaused = true
        cancelImport()
        await importTask?.value
        enrichmentTask?.cancel()
        await enrichmentTask?.value
        await managedCopyTask?.value
        return await saveNow()
    }
    func resumeSession() { sessionPaused = false; supplementMetadata() }
    func changeOrganization(_ body: @escaping (inout LibraryOrganization) -> Void) async {
        await mutate { snapshot in
            var value = snapshot.organization ?? LibraryOrganization()
            body(&value); snapshot.organization = value
        }.value
    }
    func committedLibrary() async throws -> MaterialSnapshot {
        let result = await saveNow(); try result.get(); return snapshot
    }
    func replaceLibrary(_ value: MaterialSnapshot, expected: MaterialSnapshot? = nil) async throws {
        flushPreviewUsage()
        let previous = pending
        let operation = Task<Result<Void, Error>, Never> {
            await previous?.value
            do {
                guard canWrite else { throw MaterialDatabase.error("资源库当前不可写入") }
                let current = snapshot
                if let expected {
                    guard current.materials == expected.materials, current.links == expected.links,
                          current.presets == expected.presets, current.organization == expected.organization, current.editHistory == expected.editHistory, current.tagging == expected.tagging else {
                        throw MaterialDatabase.error("素材信息已变化，本次操作取消，请重新确认")
                    }
                }
                try await database.commit(value, previous: current); apply(value)
                return .success(())
            } catch { return .failure(error) }
        }
        pending = Task { _ = await operation.value }
        try await operation.value.get()
    }
    func waitUntilReady() async { await loading?.value }
    private func reload() async {
        isLoading = true
        undoEdits.removeAll(); redoEdits.removeAll(); updateUndoFlags()
        do { apply(try await database.load()); persistenceError = nil }
        catch { persistenceError = "素材库读取失败：\(error.localizedDescription)；已禁止写入，请恢复备份" }
        isLoading = false
        let resumeURL = resumeURL
        resumableImport = await Task.detached { ImportResumeRecord.load(from: resumeURL) }.value
        supplementMetadata()
    }
    private var snapshot: MaterialSnapshot { committedSnapshot ?? MaterialSnapshot(materials: materials, links: links, presets: presets, organization: organization) }
    private func apply(_ value: MaterialSnapshot, changesQuery: Bool = true) {
        organization = value.organization ?? LibraryOrganization()
        tagging = value.tagging ?? MaterialTaggingState()
        committedSnapshot = value
        undoEdits = value.editHistory?.undo ?? []; redoEdits = value.editHistory?.redo ?? []; updateUndoFlags()
        publishedCommitRevision = commitRevision
        lastPublication = .now
        let publicationStart = Date.now
        if changesQuery || unpublishedQueryChange { queryRevision &+= 1 }
        usageRevision &+= 1
        unpublishedQueryChange = false
        materials = value.materials; links = value.links; presets = value.presets ?? []; revision += 1
        if isImporting { importTiming.published(); importTiming.record("main_publication", since: publicationStart) }
    }

    /// Each queued operation derives from the latest committed state. Failed transactions publish nothing.
    @discardableResult
    private func mutate(_ message: String? = nil, changesQuery: Bool = true,
                        onCompletion: (@MainActor (Bool) -> Void)? = nil,
                        _ change: @escaping @MainActor (inout MaterialSnapshot) -> Void) -> Task<Void, Never> {
        // Already admitted work drains during pause; new edits cannot enter an inactive store.
        guard !sessionPaused || !changesQuery else { onCompletion?(false); return Task {} }
        let previous = pending
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.waitUntilReady()
            guard self.canWrite else { onCompletion?(false); return }
            if !self.isImporting { self.isSaving = true }
            let before = self.snapshot
            var after = before
            change(&after)
            if after.materials == before.materials && after.links == before.links && after.presets == before.presets && after.organization == before.organization && after.tagging == before.tagging {
                if !self.isImporting { self.isSaving = false }
                onCompletion?(true)
                return
            }
            do {
                let editBefore = before.materials, editAfter = after.materials
                let patch = changesQuery ? await Task.detached(priority: .utility) {
                    try? MaterialUndoPatch(before: editBefore, after: editAfter)
                }.value : nil
                if let patch, !patch.changes.isEmpty {
                    var history = before.editHistory ?? MaterialUndoPatch.History()
                    history.append(patch); after.editHistory = history
                }
                // User fields and their recovery history commit atomically.
                try await self.database.commit(after, previous: before)
                self.committedSnapshot = after
                self.commitRevision &+= 1
                self.unpublishedQueryChange = self.unpublishedQueryChange || changesQuery
                if !self.isImporting || Date.now.timeIntervalSince(self.lastPublication) >= 0.5 {
                    self.apply(after, changesQuery: self.unpublishedQueryChange)
                }
                if let message { self.toast = message }
                onCompletion?(true)
            } catch {
                self.persistenceError = "素材库保存失败：\(error.localizedDescription)；本次变更未提交，请恢复备份或重新读取"
                onCompletion?(false)
            }
            if !self.isImporting { self.isSaving = false }
        }
        pending = task
        return task
    }
    /// Metadata edits share the same queue, optimistic SQLite checks, backup and undo as image fields.
    func changeTagging(_ message: String? = nil, undoable: Bool = false, checkingProposals: Set<String> = [], validating: [MaterialTaggingState.Proposal] = [],
                       _ change: @escaping @MainActor (inout MaterialTaggingState, inout [MaterialRecord]) throws -> Void) async throws {
        let previous = pending
        let operation = Task<Result<Void, Error>, Never> { [self] in
            await previous?.value
            await waitUntilReady()
            guard !sessionPaused, canWrite else { return .failure(MaterialDatabase.error("资源库当前不可写入")) }
            isSaving = true
            defer { isSaving = false }
            do {
                let before = snapshot
                var after = before, state = before.tagging ?? MaterialTaggingState()
                if !checkingProposals.isEmpty || !validating.isEmpty {
                    let validationState = state, records = before.materials, links = before.links
                    let inputs = state.proposals.filter { checkingProposals.contains($0.id) } + validating
                    let worker = Task.detached(priority: .utility) {
                        try MaterialTaggingState.staleIDs(inputs, state: validationState, records: records, links: links)
                    }
                    let stale = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard !validating.contains(where: { stale.contains($0.id) }) else { throw MaterialDatabase.error("图片、资料或关联已经变化，请重新整理；本次候选未保存") }
                    for i in state.proposals.indices where stale.contains(state.proposals[i].id) { state.proposals[i].status = "已过期" }
                }
                try change(&state, &after.materials)
                let previousState = before.tagging ?? MaterialTaggingState()
                if state.catalogKey != previousState.catalogKey || state.relationKey != previousState.relationKey {
                    let catalog = state.catalogKey, relations = state.relationKey
                    for i in state.proposals.indices where state.proposals[i].status == "待确认" &&
                        (state.proposals[i].catalogKey != catalog || state.proposals[i].relationKey != relations) {
                        state.proposals[i].status = "已过期"
                    }
                }
                after.tagging = state.isEmpty ? nil : state
                guard after.materials != before.materials || after.tagging != before.tagging else { return .success(()) }
                if undoable {
                    let oldRecords = before.materials, newRecords = after.materials, oldState = before.tagging ?? MaterialTaggingState()
                    var patch = try await Task.detached(priority: .utility) { try MaterialUndoPatch(before: oldRecords, after: newRecords) }.value
                    patch.taggingChanges = try MaterialTaggingUndo.changes(before: oldState, after: state)
                    guard patch.estimatedBytes <= 10 * 1024 * 1024 else { throw MaterialDatabase.error("本批修改超过可撤销容量，请缩小范围后重试；没有提交变更") }
                    if !patch.isEmpty {
                        var history = before.editHistory ?? MaterialUndoPatch.History()
                        history.append(patch); after.editHistory = history
                    }
                }
                try await database.commit(after, previous: before)
                commitRevision &+= 1
                apply(after, changesQuery: after.materials != before.materials || after.tagging?.terms != before.tagging?.terms)
                if let message { toast = message }
                return .success(())
            } catch { return .failure(error) }
        }
        pending = Task { _ = await operation.value }
        try await withTaskCancellationHandler { try await operation.value.get() } onCancel: { operation.cancel() }
    }

    /// Revalidate inside the queued operation; one bounded chunk corresponds to one undo step.
    func acceptTagging(ids: Set<String>, allowConflicts: Bool = false) async throws {
        let ordered = ids.sorted()
        var offset = 0
        while offset < ordered.count {
            try Task.checkCancellation()
            let chunk = Set(ordered[offset..<min(offset + 50, ordered.count)])
            try await changeTagging("已确认本批标签（最多50项，可撤销）", undoable: true, checkingProposals: chunk) { state, records in
                let positions = Dictionary(records.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
                for i in state.proposals.indices where chunk.contains(state.proposals[i].id) {
                    var proposal = state.proposals[i]
                    guard proposal.status == "待确认", let index = positions[proposal.materialID] else { continue }
                    var record = records[index]
                    guard Set(proposal.tags).isDisjoint(with: proposal.removeTags),
                          proposal.categories.groups.allSatisfy({ group in Set(group.terms).isDisjoint(with: proposal.removeCategories?.terms(for: group.dimension) ?? []) }) else {
                        throw MaterialDatabase.error("同一个词不能同时建议新增和移除，请先编辑候选")
                    }
                    guard proposal.categories.groups.allSatisfy({ ClassificationVocabulary.allowsMultiple($0.dimension) || $0.terms.count <= 1 }) else {
                        throw MaterialDatabase.error("单选分类有多个候选，请先编辑为一项再确认")
                    }
                    if MaterialTaggingState.conflicts(proposal, with: record) && !allowConflicts {
                        throw MaterialDatabase.error("包含删除已有标签或替换单选分类，请先查看差异并明确确认")
                    }
                    record.tags = Array(Set(record.tags.filter { !proposal.removeTags.contains($0) } + proposal.tags)).sorted()
                    for group in proposal.removeCategories?.groups ?? [] {
                        record.mutateClassification { value in group.terms.forEach { value.remove($0, in: group.dimension) } }
                    }
                    for group in proposal.categories.groups {
                        if ClassificationVocabulary.allowsMultiple(group.dimension) {
                            record.mutateClassification { value in group.terms.forEach { value.add($0, in: group.dimension) } }
                        } else {
                            record.mutateClassification { $0.set(group.terms, for: group.dimension) }
                        }
                    }
                    proposal.status = "已确认"; proposal.decidedAt = .now
                    records[index] = record; state.proposals[i] = proposal
                }
            }
            offset += chunk.count
        }
    }

    func saveTaggingTerm(_ input: MaterialTaggingState.Term, mergeInto: String? = nil) async throws {
        try await changeTagging("已保存标签词条，可撤销", undoable: true) { state, records in
            if state.terms.isEmpty { state.terms = state.effectiveTerms }
            var term = input
            term.name = term.name.trimmingCharacters(in: .whitespacesAndNewlines)
            term.aliases = Array(Set(term.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            guard !term.name.isEmpty, term.name.count <= 100, term.aliases.count <= 100 else { throw MaterialDatabase.error("请填写有效词条，名称不超过100字，别名不超过100项") }
            let original = state.terms.first { $0.id == term.id }
            if let old = original, old.dimension != term.dimension || old.scope != term.scope {
                let used = records.contains { $0.tags.contains(old.name) || ($0.classification?.terms(for: old.dimension).contains(old.name) ?? false) }
                guard !used else { throw MaterialDatabase.error("已有素材使用此词，请保留原维度和范围；如需调整，请新增词条后逐项确认") }
            }
            let destination = mergeInto.flatMap { id in state.terms.first { $0.id == id } }
            if mergeInto != nil {
                guard let old = original, let target = destination, old.id != target.id, old.dimension == target.dimension, old.scope == target.scope else {
                    throw MaterialDatabase.error("只能合并同维度、同范围的两个词条")
                }
                term = target
                term.aliases = Array(Set(target.aliases + old.aliases + [old.name])).sorted()
                term.favorite = target.favorite || old.favorite
            } else if state.terms.contains(where: { $0.id != term.id && $0.name.localizedCaseInsensitiveCompare(term.name) == .orderedSame && $0.dimension == term.dimension && true }) {
                throw MaterialDatabase.error("此维度已有同名词，当前存储按名称关联，请使用不同名称或合并同范围词条")
            }
            if let old = original, old.name != term.name {
                term.aliases = Array(Set(term.aliases + [old.name])).sorted()
                for i in records.indices {
                    if old.dimension.isEmpty {
                        records[i].tags = Array(Set(records[i].tags.map { $0 == old.name ? term.name : $0 })).sorted()
                    } else if records[i].classification?.contains(old.name, in: old.dimension) == true {
                        records[i].mutateClassification { value in
                            value.remove(old.name, in: old.dimension); value.add(term.name, in: old.dimension)
                        }
                    }
                }
            }
            state.terms.removeAll { $0.id == input.id || $0.id == term.id }
            state.terms.append(term)
        }
    }

    func saveNow() async -> Result<Void, Error> {
        await waitUntilReady()
        flushPreviewUsage()
        await pending?.value
        if let persistenceError { return .failure(MaterialDatabase.error(persistenceError)) }
        return .success(())
    }
    private func updateUndoFlags() { canUndoEdit = !undoEdits.isEmpty; canRedoEdit = !redoEdits.isEmpty }
    func undoEdit(redo: Bool = false) async -> Bool {
        let previous = pending
        let operation = Task<Bool, Never> { [weak self] in
            await previous?.value
            guard let self else { return false }
            guard !self.sessionPaused, self.canWrite, !self.isImporting, let patch = redo ? self.redoEdits.last : self.undoEdits.last else {
                self.toast = "当前无法撤销或重做，请完成导入并确认存在整理历史"; return false
            }
            self.isSaving = true; defer { self.isSaving = false }
            do {
                let before = self.snapshot
                var after = before
                let records = before.materials
                after.materials = try await Task.detached(priority: .userInitiated) { try patch.restore(in: records) }.value
                after.tagging = try MaterialTaggingUndo.restore(patch.taggingChanges ?? [], in: before.tagging ?? MaterialTaggingState())
                var history = before.editHistory ?? MaterialUndoPatch.History()
                if redo { history.redo.removeLast(); history.undo.append(patch.inverse) }
                else { history.undo.removeLast(); history.redo.append(patch.inverse) }
                after.editHistory = history
                try await self.database.commit(after, previous: before)
                self.commitRevision &+= 1; self.apply(after)
                self.toast = redo ? "已重做素材整理" : "已撤销素材整理"; return true
            } catch { self.toast = error.localizedDescription; return false }
        }
        pending = Task { _ = await operation.value }; return await operation.value
    }
    @discardableResult
    func retryLoad() -> Task<Void, Never> {
        guard !isImporting else { return Task {} }
        return Task {
            await pending?.value
            await reload()
            if canWrite { flushPreviewUsage() }
        }
    }
    func chooseBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "素材总库-\(UUID().uuidString.prefix(8)).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await saveNow().get(); try await database.backup(to: url); toast = "素材总库备份完成" } catch { toast = error.localizedDescription } }
    }
    func chooseRestore() {
        let panel = NSOpenPanel(); panel.title = "恢复素材库备份（保留恢复前数据库）"; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            // Restore is also the recovery path for an unwritable/corrupt
            // library; a failed usage flush must not block it.
            _ = await saveNow()
            isLoading = true
            do {
                try await database.restore(from: url)
                previewUsage.removeAll()
                await reload()
            }
            catch { persistenceError = "恢复失败：\(error.localizedDescription)"; isLoading = false }
        }
    }
    /// Usage does not change ordinary search membership or card geometry.
    /// Recent scopes/orders still observe it, and every other edit remains a
    /// full query invalidation through the regular mutation path.
    func browseQueryRevision(scope: String, sortField: MaterialSortField) -> String {
        let needsUsage = scope == "recent" || sortField == .recentlyUsed
        return "\(queryRevision)|usage:\(needsUsage ? String(usageRevision) : "ignored")"
    }

    /// Coalesce high-frequency preview navigation, with a fixed deadline from
    /// the first visit so continuous browsing cannot postpone writes forever.
    func recordPreviewUsage(_ id: String, at date: Date = .now) {
        guard canWrite, !sessionPaused else { return }
        previewUsage[id] = max(previewUsage[id] ?? .distantPast, date)
        guard previewUsageTimer == nil else { return }
        previewUsageTimer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flushPreviewUsage()
        }
    }

    private func flushPreviewUsage() {
        previewUsageTimer?.cancel()
        previewUsageTimer = nil
        guard !previewUsage.isEmpty else { return }
        let batch = previewUsage
        previewUsage.removeAll(keepingCapacity: true)
        mutate(changesQuery: false, onCompletion: { [weak self] succeeded in
            guard !succeeded, let self else { return }
            // Failed commits publish nothing; retain visits for retryLoad().
            for (id, date) in batch {
                self.previewUsage[id] = max(self.previewUsage[id] ?? .distantPast, date)
            }
        }) { snapshot in
            for index in snapshot.materials.indices {
                guard snapshot.materials[index].deletedAt == nil,
                      let date = batch[snapshot.materials[index].id] else { continue }
                snapshot.materials[index].lastUsedAt = max(snapshot.materials[index].lastUsedAt ?? .distantPast, date)
            }
        }
    }
    func materials(projectID: String? = nil, search: String = "") -> [MaterialRecord] {
        var filter = MaterialSearchFilter(); filter.search = search; filter.projectOnly = projectID != nil
        return Self.query(materials, links: links, filter: filter, projectID: projectID ?? "")
    }
    nonisolated static func sortedMaterials(_ items: [MaterialRecord], order: MaterialSortOrder) -> [MaterialRecord] {
        func number(_ item: MaterialRecord) -> Double? {
            switch order.field {
            case .imported: return item.createdAt.timeIntervalSince1970
            case .modified: return item.sourceModifiedAt?.timeIntervalSince1970
            case .created: return item.sourceCreatedAt?.timeIntervalSince1970
            case .size: return item.fileSize.map(Double.init)
            case .rating: return Double(item.rating)
            case .duration: return item.mediaMetadata?.durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            case .resolution:
                guard let w = item.mediaMetadata?.pixelWidth, let h = item.mediaMetadata?.pixelHeight, w > 0, h > 0 else { return nil }
                return Double(w) * Double(h)
            case .recentlyUsed: return item.lastUsedAt?.timeIntervalSince1970
            case .name, .format, .random: return nil
            }
        }
        return items.sorted { a, b in
            var comparison: ComparisonResult
            if order.field == .random {
                let seed = order.randomSeed ?? 0x4153534554465241
                let lhs = randomRank(id: a.id, seed: seed)
                let rhs = randomRank(id: b.id, seed: seed)
                comparison = lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
            } else if order.field == .name || order.field == .format {
                let lhs = order.field == .name ? a.name : (a.originalFilename as NSString).pathExtension.lowercased()
                let rhs = order.field == .name ? b.name : (b.originalFilename as NSString).pathExtension.lowercased()
                comparison = lhs.localizedStandardCompare(rhs)
            } else {
                let lhs = number(a), rhs = number(b)
                // Unread technical fields always follow known values in either direction.
                if lhs == nil || rhs == nil {
                    if lhs == nil && rhs != nil { return false }
                    if lhs != nil && rhs == nil { return true }
                    return a.id < b.id
                }
                comparison = lhs! == rhs! ? .orderedSame : lhs! < rhs! ? .orderedAscending : .orderedDescending
            }
            if comparison == .orderedSame { return a.id < b.id }
            return order.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    nonisolated private static func randomRank(id: String, seed: UInt64) -> UInt64 {
        var value = seed ^ 0xcbf29ce484222325
        for byte in id.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        value &+= 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    nonisolated static func formatCounts(in materials: [MaterialRecord]) -> [String: Int] {
        materials.reduce(into: [:]) { counts, material in
            counts[(material.originalFilename as NSString).pathExtension.lowercased(), default: 0] += 1
        }
    }
    nonisolated static func query(
        _ materials: [MaterialRecord],
        links: [ProjectMaterialLink],
        filter: MaterialSearchFilter,
        projectID: String,
        folders: [LocalFolderSource] = [],
        sorted: Bool = true,
        searchIndex: MaterialTextSearchIndex? = nil,
        tagging: MaterialTaggingState = .init(),
        isCancelled: () -> Bool = { false }
    ) -> [MaterialRecord] {
        guard !isCancelled() else { return [] }
        let linked = filter.projectOnly ? Set(links.filter { $0.projectID == projectID }.map(\.materialID)) : []
        let words = filter.search.localizedLowercase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let selectedFields = filter.searchFields ?? Set(MaterialSearchField.allCases)
        let usableIndex = searchIndex?.fields == selectedFields && searchIndex?.localeIdentifier == Locale.current.identifier ? searchIndex : nil
        let textContext = MaterialSearchText.Context(fields: words.isEmpty ? [] : selectedFields, links: links, folders: folders, tagging: tagging)
        let matchesFilter: (MaterialRecord) -> Bool = { m in
            guard m.deletedAt == nil, !filter.projectOnly || linked.contains(m.id),
                  filter.kinds.isEmpty || filter.kinds.contains(m.kind),
                  filter.formats.isEmpty || filter.formats.contains((m.originalFilename as NSString).pathExtension.lowercased()),
                  m.rating >= filter.minimumRating,
                  !filter.commonOnly || m.production?.isCommon == true,
                  filter.purpose == "全部" || m.production?.purpose == filter.purpose else { return false }
            if let tags = filter.requiredTags, !tags.isSubset(of: Set(m.tags)) { return false }
            if let colors = filter.colorLabels, !colors.isEmpty, !colors.contains(m.colorLabel ?? "未标记") { return false }
            if let classificationFilters = filter.classificationFilters, !classificationFilters.isEmpty {
                guard let classification = m.classification, classification.matches(classificationFilters) else { return false }
            }
            if let rating = filter.exactRating, m.rating != rating { return false }
            if let folders = filter.folderPaths, !folders.isEmpty {
                guard let source = m.sourcePath else { return false }
                let path = URL(fileURLWithPath: source).standardizedFileURL.path
                guard folders.contains(where: { folder in
                    let root = URL(fileURLWithPath: folder).standardizedFileURL.path
                    return path.hasPrefix(root == "/" ? "/" : root + "/")
                }) else { return false }
            }
            let metadata = m.mediaMetadata
            if let min = filter.minimumDuration, !(metadata?.durationSeconds.map { $0 >= min } ?? false) { return false }
            if let max = filter.maximumDuration, !(metadata?.durationSeconds.map { $0 <= max } ?? false) { return false }
            if filter.minimumPixels > 0, max(metadata?.pixelWidth ?? 0, metadata?.pixelHeight ?? 0) < filter.minimumPixels { return false }
            if filter.orientation != "全部" {
                guard let w = metadata?.pixelWidth, let h = metadata?.pixelHeight, w > 0, h > 0 else { return false }
                if filter.orientation == "横屏" && w <= h { return false }
                if filter.orientation == "竖屏" && w >= h { return false }
                if filter.orientation == "方形" && w != h { return false }
            }
            // Empty search is a browse/filter operation, not a text-index build.
            guard !words.isEmpty else { return true }
            if let matches = usableIndex?.matches(m.id, words: words) { return matches }
            let haystack = MaterialSearchText.normalized(m, fields: selectedFields, context: textContext)
            return words.allSatisfy { haystack.contains($0) }
        }
        var matches: [MaterialRecord] = []
        matches.reserveCapacity(materials.count)
        for (index, material) in materials.enumerated() {
            // Cancel at bounded intervals without checking task state for every field.
            if index % 128 == 0, isCancelled() { return [] }
            if matchesFilter(material) { matches.append(material) }
        }
        guard !isCancelled() else { return [] }
        return sorted ? matches.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt } : matches
    }
    func savePreset(name: String, filter: MaterialSearchFilter) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        mutate("筛选组合已保存") { value in
            var presets = value.presets ?? []
            if let index = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
                presets[index].name = trimmedName
                presets[index].filter = filter
            } else {
                presets.append(MaterialFilterPreset(name: trimmedName, filter: filter))
            }
            value.presets = presets
        }
    }
    func link(for materialID: String, projectID: String) -> ProjectMaterialLink? { links.first { $0.materialID == materialID && $0.projectID == projectID } }
    func chooseFiles() { choose(audioOnly: false) }
    func chooseAudioFiles() { choose(audioOnly: true) }
    private func choose(audioOnly: Bool) {
        let panel = NSOpenPanel(); panel.title = "导入生产素材"; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true; panel.allowedContentTypes = audioOnly ? [.audio] : [.data]
        guard panel.runModal() == .OK else { return }
        if audioOnly { importAudioFiles(panel.urls) } else { importFiles(panel.urls) }
    }
    /// Read linked directories again so the gallery includes files added since
    /// the initial link. Reuse the bounded indexer; unchanged records, edits and
    /// trashed records keep their identities. Never overwrite an unfinished job.
    func readLinkedFolders(files: [URL]? = nil, directories: [URL] = []) async -> Bool {
        guard !readingLinkedFolders, !sessionPaused, canWrite, !isImporting,
              resumableImport == nil else { return false }
        let roots = files ?? organization.folders.map { URL(fileURLWithPath: $0.rootPath).standardizedFileURL }
        guard !roots.isEmpty else { return false }
        readingLinkedFolders = true
        defer { readingLinkedFolders = false }
        importProjectID = nil
        if files != nil {
            await changeOrganization { org in
                for i in org.folders.indices {
                    let root = URL(fileURLWithPath: org.folders[i].rootPath).standardizedFileURL.path
                    let additions = directories.compactMap { url -> String? in
                        let path = url.standardizedFileURL.path
                        if path == root { return "" }
                        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
                    }
                    org.folders[i].directoryPaths = Array(Set(org.folders[i].directoryPaths + additions)).sorted()
                }
            }
        }
        guard !sessionPaused else { return false }
        importFiles(roots)
        await importTask?.value
        if !isImporting { importProgressVisible = importFailed > 0 || importCancelled > 0 }
        return true
    }

    func importAudioFiles(_ urls: [URL]) { importFiles(urls, limitingTo: [.audio]) }
    func importFiles(_ urls: [URL]) { importFiles(urls, limitingTo: nil) }
    func cancelImport() { guard isImporting else { return }; importPauseRequested = false; importPhase = "正在取消"; importTask?.cancel() }
    func pauseImport() { guard isImporting else { return }; importPauseRequested = true; importPhase = "正在暂停"; importTask?.cancel() }
    private func importFiles(_ urls: [URL], limitingTo kinds: Set<MaterialKind>?, resuming: ImportResumeRecord? = nil) {
        guard !urls.isEmpty, !sessionPaused else { return }
        guard !isImporting else {
            toast = "正在导入，请等待本批完成或取消后重新拖入"
            return
        }
        enrichmentTask?.cancel()
        importPauseRequested = false
        lastPublication = .distantPast
        importTiming = ImportTiming()
        let jobID = resuming?.id ?? UUID()
        importController.job = ImportJobProgress(id: jobID, stage: "正在发现素材")
        isImporting = true; importResults = []; importTotal = 0
        importProgressVisible = true; importPhase = "正在发现素材"
        importDiscovered = 0; importProcessed = 0; importRead = 0
        importSaveCount = 0; importReadSeconds = 0; importSaveSeconds = 0
        importScanCompleted = false; importEstimatedRemainingSeconds = nil
        importAdded = 0; importDuplicate = 0; importFailed = 0; importSkipped = 0; importCancelled = 0
        importCurrentFile = urls.map(\.lastPathComponent).joined(separator: "、")
        importTask = Task {
            await waitUntilReady()
            defer {
                if publishedCommitRevision != commitRevision, let committedSnapshot { apply(committedSnapshot) }
                importTiming.report("material")
                isImporting = false
                supplementMetadata()
            }
            let job = ImportResumeRecord(id: jobID, paths: urls.map(\.path), projectID: importProjectID, localFolder: nil, audioOnly: kinds == [.audio], createdAt: resuming?.createdAt ?? .now)
            let resumeURL = resumeURL
            do { try await Task.detached { try job.save(to: resumeURL) }.value; resumableImport = job }
            catch { importPhase = "无法保存恢复任务"; toast = error.localizedDescription; return }
            let roots = await Task.detached {
                urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }.value
            let projectID = importProjectID
            await changeOrganization { org in
                for url in roots {
                    if let existing = org.folders.first(where: { $0.rootPath == url.path }) {
                        if let projectID { org.folderProjects[existing.id] = Array(Set((org.folderProjects[existing.id] ?? []) + [projectID])).sorted() }
                    } else {
                        let f = LocalFolderSource(id: UUID().uuidString, name: url.lastPathComponent, rootPath: url.path, directoryPaths: [""], createdAt: .now)
                        org.folders.append(f); org.folderProjects[f.id] = projectID.map { [$0] } ?? []
                    }
                }
            }
            guard canWrite else {
                importPhase = "无法导入"
                appendImportResults([.init(path: importCurrentFile, message: persistenceError ?? "素材库不可写")])
                return
            }

            let scanner = ImportDirectoryScanner(urls: urls)
            var firstBatch = true
            var knownSourceIdentities = Set(materials.compactMap(Self.sourceIdentity))
            // Imported/migrated dates can differ from Foundation file dates by
            // a sub-microsecond conversion error. Index once, outside the batches.
            let knownSourceDates = Dictionary(grouping: materials.compactMap { record -> (String, Date)? in
                guard let path = record.sourcePath, let modified = record.sourceModifiedAt else { return nil }
                return (Self.sourcePathSizeKey(path: path, fileSize: record.fileSize), modified)
            }, by: { $0.0 }).mapValues { $0.map { $0.1 } }
            let processingStarted = Date.now
            while !Task.isCancelled && canWrite && !importScanCompleted {
                await Self.yieldToBrowsing()
                guard !Task.isCancelled else { break }
                let scanStarted = Date.now
                let batch = await scanner.next(first: firstBatch)
                importTiming.record("scan", since: scanStarted)
                if Task.isCancelled { break }
                importDiscovered += batch.files.count
                importTotal = importDiscovered
                importScanCompleted = batch.finished
                if !batch.directories.isEmpty {
                    let directories = batch.directories
                    await changeOrganization { org in
                        for i in org.folders.indices {
                            let root = org.folders[i].rootPath
                            let additions = directories.compactMap { url -> String? in
                                if url.path == root { return "" }
                                return url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : nil
                            }
                            org.folders[i].directoryPaths = Array(Set(org.folders[i].directoryPaths + additions)).sorted()
                        }
                    }
                }
                appendImportResults(batch.errors.map { .init(path: "目录扫描", message: $0) })
                if !batch.files.isEmpty {
                    importPhase = "正在登记，素材可立即浏览"
                    let outcome = await processImportBatch(batch.files, limitingTo: kinds,
                        cachedMetadata: [:], knownSourceIdentities: knownSourceIdentities, knownSourceDates: knownSourceDates)
                    applyImportBatchOutcome(outcome, processedCount: batch.files.count, processingStarted: processingStarted)
                    knownSourceIdentities.formUnion(outcome.sourceIdentities)
                }
                firstBatch = false
            }
            if Task.isCancelled && importProcessed == importTotal {
                appendImportResults([.init(path: "未扫描部分", message: "已取消", outcome: "cancelled")])
            }
            if importProcessed < importTotal {
                let outcome = Task.isCancelled ? "cancelled" : "failed"
                let message = Task.isCancelled ? "已取消" : "未处理：数据库不可写"
                let remainder = max(0, importTotal - importProcessed)
                importResults.append(.init(path: "剩余 \(remainder) 项", message: message, outcome: outcome))
                if Task.isCancelled { importCancelled += remainder }
                else { importFailed += remainder }
            }
            toast = "导入结束：已处理 \(importProcessed) / \(importTotal) 项"
            importPhase = Task.isCancelled ? (importPauseRequested ? "已暂停，可继续此任务" : "已取消，可恢复未完成部分") : persistenceError != nil ? "导入中止" : importResults.isEmpty ? "文件夹为空或没有可读取文件" : "导入完成"
            importEstimatedRemainingSeconds = Task.isCancelled || !canWrite ? nil : 0
            importController.job?.advance(stage: importPhase, discovered: importDiscovered, registered: importAdded, skipped: importDuplicate + importSkipped, failed: importFailed, scanCompleted: importScanCompleted, finished: true)
            importCurrentFile = ""
            if !Task.isCancelled && canWrite && importScanCompleted && importFailed == 0 {
                do { try await Task.detached { try ImportResumeRecord.clear(at: resumeURL) }.value; resumableImport = nil }
                catch { toast = "导入完成，恢复记录清理失败" }
            }
        }
    }

    private func processImportBatch(
        _ batch: [URL], limitingTo kinds: Set<MaterialKind>?,
        cachedMetadata: [String: MaterialMediaMetadata], knownSourceIdentities: Set<String>, knownSourceDates: [String: [Date]]
    ) async -> MaterialImportBatchOutcome {
        var messages: [MaterialImportResult] = []
        var identities = Set<String>()
        var urlsToRead: [URL] = []
        let sourceIdentities = await Task.detached(priority: .userInitiated) {
            batch.map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize.map(Int64.init)
                let modified = values?.contentModificationDate
                let identity = values.map { _ in Self.sourceIdentity(path: url.path, fileSize: size, modifiedAt: modified) }
                let key = Self.sourcePathSizeKey(path: url.path, fileSize: size)
                let sameSource = modified.map { current in
                    knownSourceDates[key]?.contains { abs($0.timeIntervalSince(current)) <= 0.000_001 } == true
                } ?? false
                return (url, identity, sameSource)
            }
        }.value
        for (url, identity, sameSource) in sourceIdentities {
            if let identity, knownSourceIdentities.contains(identity) || sameSource {
                identities.insert(identity)
                messages.append(.init(path: url.path, message: "来源未变化，保留原记录", outcome: "duplicate"))
            } else {
                urlsToRead.append(url)
            }
        }

        let readingStarted = Date.now
        let readURLs = urlsToRead
        let worker = Task.detached(priority: .userInitiated) {
            var values: [(URL, MaterialRecord?)] = []
            for url in readURLs {
                guard !Task.isCancelled else { break }
                values.append((url, await Self.record(url, cachedMetadata: cachedMetadata, lightweight: true)))
            }
            return values
        }
        let results = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        importRead += results.count
        importCurrentFile = results.last?.0.lastPathComponent ?? ""
        importTiming.record("lightweight_registration", since: readingStarted)
        let readSeconds = Date.now.timeIntervalSince(readingStarted)
        importReadSeconds += readSeconds

        var metadata: [String: MaterialMediaMetadata] = [:]
        for (_, record) in results {
            if let record, let value = record.mediaMetadata { metadata[record.fingerprint] = value }
        }
        let accepted = results.filter { url, record in
            guard let record else {
                messages.append(.init(path: url.path, message: "读取失败，未入库"))
                return false
            }
            if let kinds, !kinds.contains(record.kind) {
                messages.append(.init(path: url.path, message: "跳过非音频文件", outcome: "skipped"))
                return false
            }
            return true
        }

        let savingStarted = Date.now
        let revisionBeforeSave = commitRevision
        let projectID = importProjectID
        let batchPaths = Set(batch.map(\.path))
        let transaction = mutate { snapshot in
            var fingerprintIndices = Dictionary(snapshot.materials.enumerated().map { ($0.element.fingerprint, $0.offset) }, uniquingKeysWith: { first, _ in first })
            for (url, record) in accepted {
                guard let record else { continue }
                if let identity = Self.sourceIdentity(record) { identities.insert(identity) }
                if let i = fingerprintIndices[record.fingerprint] {
                    if snapshot.materials[i].sourceMissing {
                        snapshot.materials[i].sourcePath = record.sourcePath
                        snapshot.materials[i].sourceLocations = record.sourceLocations
                        snapshot.materials[i].sourceCreatedAt = record.sourceCreatedAt
                        snapshot.materials[i].sourceModifiedAt = record.sourceModifiedAt
                        snapshot.materials[i].mediaMetadata = record.mediaMetadata
                    }
                    messages.append(.init(path: url.path, message: "重复，保留原记录", outcome: "duplicate"))
                } else {
                    fingerprintIndices[record.fingerprint] = snapshot.materials.count
                    snapshot.materials.append(record)
                    messages.append(.init(path: url.path, message: record.mediaMetadata?.issue ?? "已入库", outcome: "added"))
                }
            }
            if let projectID {
                for record in snapshot.materials where batchPaths.contains(record.sourcePath ?? "") {
                    if !snapshot.links.contains(where: { $0.projectID == projectID && $0.materialID == record.id }) {
                        snapshot.links.append(ProjectMaterialLink(id: UUID().uuidString, projectID: projectID, materialID: record.id, use: .candidate, createdAt: .now))
                    }
                }
            }
        }
        await transaction.value
        importTiming.record("persistence_transaction", since: savingStarted)
        let saveSeconds = Date.now.timeIntervalSince(savingStarted)
        let didSave = commitRevision != revisionBeforeSave
        if persistenceError != nil {
            messages = batch.map { .init(path: $0.path, message: "保存失败，未提交") }
            identities.removeAll()
        }
        return MaterialImportBatchOutcome(
            messages: messages, sourceIdentities: identities, metadata: metadata,
            readCount: urlsToRead.count, saveSeconds: saveSeconds, didSave: didSave
        )
    }

    private func applyImportBatchOutcome(
        _ outcome: MaterialImportBatchOutcome, processedCount: Int, processingStarted: Date
    ) {
        importSaveSeconds += outcome.saveSeconds
        if outcome.didSave { importSaveCount += 1 }
        appendImportResults(outcome.messages)
        if persistenceError == nil { importProcessed += processedCount }
        importController.job?.advance(stage: importPhase, discovered: importDiscovered,
            registered: importAdded, skipped: importDuplicate + importSkipped, failed: importFailed,
            scanCompleted: importScanCompleted, finished: false)
        guard importScanCompleted, importProcessed >= 32, Date.now.timeIntervalSince(processingStarted) >= 2, importProcessed < importTotal else {
            importEstimatedRemainingSeconds = importProcessed >= importTotal && importTotal > 0 ? 0 : nil
            return
        }
        importEstimatedRemainingSeconds = Date.now.timeIntervalSince(processingStarted)
            / Double(importProcessed) * Double(importTotal - importProcessed)
    }

    private func appendImportResults(_ results: [MaterialImportResult]) {
        guard !results.isEmpty else { return }
        importResults.append(contentsOf: results)
        for result in results {
            switch result.outcome {
            case "added": importAdded += 1
            case "duplicate": importDuplicate += 1
            case "skipped": importSkipped += 1
            case "cancelled": importCancelled += 1
            default: importFailed += 1
            }
        }
    }
    func addLink(_ rawURL: String) {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { toast = "请输入有效链接"; return }
        mutate("链接已加入") { snapshot in
            let fingerprint = "url:" + url.absoluteString
            guard !snapshot.materials.contains(where: { $0.fingerprint == fingerprint }) else { return }
            snapshot.materials.append(MaterialRecord(id: UUID().uuidString, kind: .link, name: url.host ?? rawURL, sourceURL: url.absoluteString, originalFilename: rawURL, fingerprint: fingerprint, sourceLocations: [], createdAt: .now, tags: [], rating: 0, note: ""))
        }
    }
    func setLink(materialID: String, projectID: String, use: ProjectMaterialUse) {
        mutate("已加入当前项目") { snapshot in
            if let i = snapshot.links.firstIndex(where: { $0.materialID == materialID && $0.projectID == projectID && ($0.shot ?? "").isEmpty }) { snapshot.links[i].use = use }
            else { snapshot.links.append(ProjectMaterialLink(id: UUID().uuidString, projectID: projectID, materialID: materialID, use: use, createdAt: .now)) }
        }
    }
    func saveUsage(_ link: ProjectMaterialLink) {
        guard validRange(link) else { toast = "区间无效：入点必须小于出点且在素材时长内"; return }
        mutate("镜头引用已保存") { snapshot in
            if let i = snapshot.links.firstIndex(where: { $0.id == link.id }) { snapshot.links[i] = link } else { snapshot.links.append(link) }
        }
    }
    func validRange(_ link: ProjectMaterialLink) -> Bool {
        let duration = materials.first { $0.id == link.materialID }?.mediaMetadata?.durationSeconds
        let start = link.inPoint ?? 0
        guard start.isFinite, start >= 0 else { return false }
        if let end = link.outPoint { guard end.isFinite, end > start, duration.map({ end <= $0 }) ?? false else { return false } }
        return duration.map { start < $0 || (start == 0 && $0 == 0) } ?? (link.inPoint == nil && link.outPoint == nil)
    }
    func removeUsage(_ id: String) { mutate("已移除引用；源文件保留") { $0.links.removeAll { $0.id == id } } }
    func removeLink(materialID: String, projectID: String) { mutate("已移出当前项目；全局素材和原文件保持不变") { $0.links.removeAll { $0.materialID == materialID && $0.projectID == projectID } } }
    func update(_ id: String, body: @escaping (inout MaterialRecord) -> Void) {
        mutate { snapshot in if let i = snapshot.materials.firstIndex(where: { $0.id == id }) { body(&snapshot.materials[i]) } }
    }
    func batchUpdate(_ ids: Set<String>, body: @escaping (inout MaterialRecord) -> Void) {
        mutate { snapshot in for i in snapshot.materials.indices where ids.contains(snapshot.materials[i].id) { body(&snapshot.materials[i]) } }
    }
    func setVersion(_ id: String, relativeTo parentID: String) {
        mutate("已关联版本；既有镜头选用不变") { snapshot in
            guard let parent = snapshot.materials.first(where: { $0.id == parentID }), let i = snapshot.materials.firstIndex(where: { $0.id == id }), parent.kind == snapshot.materials[i].kind, parent.id != id else { return }
            let oldGroup = snapshot.materials[i].production?.versionGroupID ?? id
            let targetGroup = parent.production?.versionGroupID ?? parent.id
            for index in snapshot.materials.indices where (snapshot.materials[index].production?.versionGroupID ?? snapshot.materials[index].id) == oldGroup {
                var production = snapshot.materials[index].production ?? MaterialProductionMetadata()
                production.versionGroupID = targetGroup
                snapshot.materials[index].production = production
            }
        }
    }
    func open(_ material: MaterialRecord) {
        if material.kind == .link, let raw = material.sourceURL, let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        else if let location = material.fileLocation, location.exists { NSWorkspace.shared.open(location.url) }
        else { toast = "源文件不可用" }
    }
    @discardableResult func reveal(_ location: AssetFileLocation) -> Bool {
        guard location.exists else { toast = "来源位置已经失联"; return false }
        NSWorkspace.shared.activateFileViewerSelecting([location.url]); return true
    }
    func copyPath(_ location: AssetFileLocation) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(location.path, forType: .string); toast = "已复制来源路径" }
    func copyOriginalImage(_ material: MaterialRecord) {
        guard material.kind == .image else { toast = "只有图片素材可以复制原图"; return }
        guard let location = material.fileLocation, location.exists else { toast = "原图文件已移动或磁盘未连接"; return }
        toast = "正在复制原图…"
        Task {
            do {
                try await OriginalImageClipboard.copyImageInBackground(at: location.url)
                toast = "已复制原图，可以直接粘贴"
            } catch {
                toast = error.localizedDescription
            }
        }
    }
    func relocate(_ id: String, onComplete: (@MainActor () -> Void)? = nil) {
        let panel = NSOpenPanel(); panel.title = "定位同一内容的原文件"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await relocate(id, to: url)
                toast = "原文件已重新定位；标签与引用保留"
                onComplete?()
            } catch { toast = error.localizedDescription }
        }
    }

    func relocate(_ id: String, to url: URL) async throws {
        let record = await Task.detached { await Self.record(url) }.value
        let before = try await committedLibrary()
        guard let record, let index = before.materials.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw MaterialDatabase.error("素材已变化或所选文件不可读取")
        }
        let original = before.materials[index]
        guard record.fingerprint == (original.contentFingerprint ?? original.fingerprint), record.kind == original.kind else {
            throw MaterialDatabase.error("内容不同或缺少可核验的内容指纹，请作为新版本导入")
        }
        var after = before
        after.materials[index].sourcePath = record.sourcePath
        after.materials[index].sourceLocations = record.sourceLocations
        after.materials[index].originalFilename = record.originalFilename
        after.materials[index].fileSize = record.fileSize
        after.materials[index].sourceCreatedAt = record.sourceCreatedAt
        after.materials[index].sourceModifiedAt = record.sourceModifiedAt
        after.materials[index].mediaMetadata = record.mediaMetadata
        try await replaceLibrary(after, expected: before)
    }

    nonisolated private static func sourceIdentity(_ record: MaterialRecord) -> String? {
        guard let path = record.sourcePath, !path.isEmpty else { return nil }
        return sourceIdentity(
            path: path,
            fileSize: record.fileSize,
            modifiedAt: record.sourceModifiedAt
        )
    }

    nonisolated private static func sourceIdentity(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return sourceIdentity(
            path: url.path,
            fileSize: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate
        )
    }

    nonisolated private static func sourcePathSizeKey(path: String, fileSize: Int64?) -> String {
        "\(URL(fileURLWithPath: path).standardizedFileURL.path)|\(fileSize ?? 0)"
    }

    nonisolated private static func sourceIdentity(path: String, fileSize: Int64?, modifiedAt: Date?) -> String {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let modified = modifiedAt?.timeIntervalSince1970.description ?? "0"
        return "\(normalizedPath)|\(fileSize ?? 0)|\(modified)"
    }

    nonisolated static func scanImportURLs(
        _ urls: [URL], progress: @Sendable (Int, String) async -> Void
    ) async -> (files: [URL], errors: [MaterialImportResult]) {
        var files: [URL] = []
        var errors: [MaterialImportResult] = []
        for url in urls {
            if Task.isCancelled { break }
            await progress(files.count, url.path)
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory != true { files.append(url); continue }
                // Enumerator reports inaccessible directories instead of silently treating them as empty.
                var directoryErrors: [MaterialImportResult] = []
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { failedURL, error in
                        directoryErrors.append(.init(path: failedURL.path, message: "读取失败：" + error.localizedDescription))
                        return true
                    })
                if let enumerator {
                    var visited = 0
                    while let child = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            files.append(child)
                        }
                        visited += 1
                        if visited % 100 == 0 { await progress(files.count, child.path) }
                    }
                } else {
                    directoryErrors.append(.init(path: url.path, message: "无法读取目录，请检查权限或磁盘连接"))
                }
                errors.append(contentsOf: directoryErrors)
            } catch {
                errors.append(.init(path: url.path, message: "读取失败：" + error.localizedDescription))
            }
        }
        await progress(files.count, "扫描结束")
        return (files, errors)
    }
    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [url] }
            return (FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) ?? []
        }
    }
    nonisolated static func record(_ url: URL, cachedMetadata: [String: MaterialMediaMetadata] = [:], lightweight: Bool = false) async -> MaterialRecord? {
        let before = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let before else { return nil }
        let fingerprint: String
        if lightweight {
            let identity = sourceIdentity(path: url.path, fileSize: before.fileSize.map(Int64.init), modifiedAt: before.contentModificationDate)
            fingerprint = "source:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        } else {
            guard let hash = streamFingerprint(url) else { return nil }
            fingerprint = hash
        }
        let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after?.fileSize, before.contentModificationDate == after?.contentModificationDate else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: MaterialKind
        if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .movie) { kind = .video }
        else if type.conforms(to: .audio) { kind = .audio }
        else if type.conforms(to: .font) { kind = .font }
        else if type.conforms(to: .pdf) || type.conforms(to: .text) { kind = .document }
        else if ["psd", "aep", "blend", "prproj", "fcpxml"].contains(url.pathExtension.lowercased()) { kind = .projectFile }
        else { kind = .other }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let metadata: MaterialMediaMetadata?
        if lightweight { metadata = nil }
        else if let cached = cachedMetadata[fingerprint] { metadata = cached }
        else {
            metadata = await mediaMetadata(for: url, type: type, kind: kind)
            if kind == .image { SSDPreviewCache.warmThumbnail(path: url.path, size: Int64(before.fileSize ?? 0), modified: before.contentModificationDate) }
        }
        return MaterialRecord(
            id: UUID().uuidString,
            kind: kind,
            name: url.deletingPathExtension().lastPathComponent,
            sourcePath: url.path,
            sourceURL: nil,
            originalFilename: url.lastPathComponent,
            fingerprint: fingerprint,
            sourceLocations: [url.path],
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            sourceCreatedAt: attributes?[.creationDate] as? Date,
            sourceModifiedAt: attributes?[.modificationDate] as? Date,
            mediaMetadata: metadata,
            createdAt: .now,
            tags: [],
            rating: 0,
            note: ""
        )
    }

    nonisolated static func verifiedContentFingerprint(_ material: MaterialRecord) -> String? {
        if let hash = material.contentFingerprint { return hash }
        if !material.fingerprint.hasPrefix("source:") { return material.fingerprint }
        guard let path = material.sourcePath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let before = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              before.fileSize.map(Int64.init) == material.fileSize,
              before.contentModificationDate == material.sourceModifiedAt,
              let hash = streamFingerprint(url),
              let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { return nil }
        return hash
    }

    nonisolated static func streamFingerprint(_ url: URL, chunkSize: Int = 1_048_576) -> String? {
        ImportContentReadGate.hashLock.lock()
        defer { ImportContentReadGate.hashLock.unlock() }
        guard chunkSize > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                hash.update(data: data)
            }
        } catch { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func mediaMetadata(for url: URL, type: UTType, kind: MaterialKind) async -> MaterialMediaMetadata? {
        var result = MaterialMediaMetadata(contentTypeIdentifier: type.identifier)
        if kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            result.frameCount = CGImageSourceGetCount(source)
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                result.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                result.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            }
        } else if kind == .video || kind == .audio {
            let asset = AVURLAsset(url: url)
            result.isPlayable = try? await asset.load(.isPlayable)
            result.hasAudio = (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false
            if result.isPlayable != true { result.issue = "编码不支持或媒体损坏" }
            let seconds = (try? await asset.load(.duration).seconds) ?? .nan
            if seconds.isFinite, seconds >= 0 { result.durationSeconds = seconds }
            if kind == .video, let track = try? await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let size = naturalSize.applying(transform)
                result.pixelWidth = Int(abs(size.width))
                result.pixelHeight = Int(abs(size.height))
                let frameRate = (try? await track.load(.nominalFrameRate)) ?? 0
                if frameRate > 0 { result.frameRate = Double(frameRate) }
            }
            if kind == .audio,
               let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let descriptions = try? await track.load(.formatDescriptions),
               let description = descriptions.first,
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                let sampleRate = stream.pointee.mSampleRate
                let channelCount = stream.pointee.mChannelsPerFrame
                if sampleRate > 0 { result.sampleRate = sampleRate }
                if channelCount > 0 { result.channelCount = Int(channelCount) }
            }
        }
        if kind == .image && result.pixelWidth == nil { result.issue = "图片损坏或格式不支持" }
        return result
    }
}
