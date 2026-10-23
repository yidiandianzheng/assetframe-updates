import AppKit
import Combine
import Foundation
import AVFoundation

@MainActor
final class LocalCLIService: ObservableObject {
    @Published private(set) var issue: String?
    private weak var session: LibrarySession?
    private var transport: LocalCLITransport?
    private var terminationObserver: NSObjectProtocol?
    private var navigationOwner: UUID?
    private var navigation: ((String, [String: String]) throws -> CLIValue)?
    private let launchedAt = Date()

    static let commands: [String: [String]] = [
        "status": [], "capabilities": [], "libraries": [], "diagnostics": [],
        "libraries.open": ["id"], "cache.status": [], "cache.release-memory": [],
        "edit.undo": [], "edit.redo": [], "import.pause": [], "import.resume": [],
        "materials.list": ["query", "kind", "limit", "offset", "includeDeleted"],
        "materials.show": ["id"], "browse.status": [], "browse.search": ["query"],
        "browse.focus": ["id"], "browse.preview": ["id"], "browse.exit": [],
        "playback.status": [], "playback.play": [], "playback.pause": [], "playback.seek": ["seconds"]
    ]

    func start(session: LibrarySession, qaRoot: URL?) {
        guard transport == nil else { return }
        self.session = session
        let root = session.applicationSupportRoot
        let server = LocalCLITransport(directory: root.appendingPathComponent("CLI")) { [weak self] request in
            await self?.handle(request) ?? .failure(request.id, "unavailable", "工作区尚未就绪")
        }
        server.onStateChange = { [weak self] in self?.issue = $0 }
        transport = server
        do { try server.start() } catch { issue = error.localizedDescription; transport = nil }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.transport?.stop() }
        }
    }

    func registerNavigation(owner: UUID, handler: @escaping (String, [String: String]) throws -> CLIValue) {
        navigationOwner = owner; navigation = handler
    }
    func unregisterNavigation(owner: UUID) {
        guard navigationOwner == owner else { return }
        navigation = nil; navigationOwner = nil
    }

    private func handle(_ request: CLIRequest) async -> CLIResponse {
        do {
            guard let allowed = Self.commands[request.command] else { throw CLIError(code: "unknown_command", message: "未知命令，请查询capabilities") }
            guard Set(request.arguments.keys).isSubset(of: Set(allowed)) else { throw CLIError(code: "invalid_argument", message: "命令包含不支持的参数") }
            let result = try await execute(request.command, request.arguments)
            return CLIResponse(id: request.id, ok: true, result: result)
        } catch let error as CLIError { return CLIResponse(id: request.id, ok: false, error: error) }
        catch { return .failure(request.id, "command_failed", error.localizedDescription) }
    }

    private func execute(_ command: String, _ args: [String: String]) async throws -> CLIValue {
        guard let session else { throw CLIError(code: "unavailable", message: "工作区尚未就绪") }
        if command == "capabilities" { return try .encoded(Self.commands) }
        if command == "libraries" { return try .encoded(session.registry.locations) }
        if command == "status" || command == "diagnostics" {
            var state: [String: CLIValue] = [
                "product": .string(session.product.rawValue), "projectWorkspaceAvailable": .bool(session.projectWorkspace != nil),
                "projectCount": .number(Double(session.projectWorkspace?.library.registry.projects.count ?? 0)),
                "appVersion": .string(AppVersion.display), "buildLabel": .string(AppVersion.annotatedDisplay),
                "protocolVersion": .number(1), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "uptimeSeconds": .number(Date().timeIntervalSince(launchedAt)),
                "libraryID": .optional(session.descriptor?.id), "libraryName": .optional(session.descriptor?.name),
                "libraryPath": .optional(session.root?.path), "busy": .bool(session.busy),
                "stage": .string(session.stage), "error": .optional(session.error),
                "lastOpenSeconds": .number(session.lastOpenSeconds), "lastOpenReusedStore": .bool(session.lastOpenReusedStore),
                "navigationAvailable": .bool(navigation != nil),
                "browse": try .encoded(session.browse), "playback": playbackState(),
                "previewPipeline": try .encoded(PreviewImagePipeline.shared.workSnapshot()),
                "cacheBudget": try .encoded(PreviewCacheBudget.shared.snapshot(root: SSDPreviewCache.root))
            ]
            if let navigation { state["workspace"] = try navigation("browse.status", [:]) }
            if let store = session.store {
                state["store"] = .object([
                    "recordCount": .number(Double(store.materials.count)), "loading": .bool(store.isLoading),
                    "importing": .bool(store.isImporting), "managedCopyJobs": .number(Double(store.managedCopyJobs)),
                    "persistenceError": .optional(store.persistenceError),
                    "canUndoEdit": .bool(store.canUndoEdit), "canRedoEdit": .bool(store.canRedoEdit),
                    "undoHistoryCount": .number(Double(store.undoHistoryCount)), "redoHistoryCount": .number(Double(store.redoHistoryCount)),
                    "importPhase": .string(store.importPhase), "importProcessed": .number(Double(store.importProcessed)),
                    "importAdded": .number(Double(store.importAdded)), "resumableImport": .bool(store.resumableImport != nil),
                    "queryRevision": .number(Double(store.queryRevision)), "usageRevision": .number(Double(store.usageRevision)),
                    "persistenceCommitCount": .number(Double(store.persistenceCommitCount))
                ])
            }
            if command == "diagnostics" {
                state["systemVersion"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
                state["endpointPath"] = .optional(transport?.endpointURL.path)
                state["transportIssue"] = .optional(issue)
                state["commands"] = try .encoded(Self.commands)
                state["diagnosticScope"] = .string("当前内存状态；未执行扫描、数据库迁移、完整性修复或远程请求")
            }
            return .object(state)
        }
        if command == "playback.status" { return playbackState() }
        if command == "playback.pause" { MaterialPlaybackController.shared.pause(); return playbackState() }
        let store = try readyStore(session)
        if command == "cache.status" {
            guard let id = session.descriptor?.id else { throw CLIError(code: "library_not_ready", message: "资源库尚未就绪") }
            let root = try SSDPreviewCache.libraryRoot(id)
            return try .encoded(await Task.detached { PreviewCacheInventory.read(root: root) }.value)
        }
        if command == "cache.release-memory" { PreviewImagePipeline.shared.cancelPendingAndClearMemory(); return .object(["released": .bool(true)]) }
        if ["edit.undo", "edit.redo", "libraries.open", "import.pause", "import.resume"].contains(command) {
            guard let navigation else { throw CLIError(code: "workspace_unavailable", message: "需要打开素材工作区窗口") }
            _ = try navigation("browse.check", [:])
            if command == "libraries.open" {
                guard let id = args["id"], let target = session.registry.locations.first(where: { $0.id == id }) else { throw CLIError(code: "not_found", message: "只支持已登记的资源库ID") }
                await session.open(URL(fileURLWithPath: target.path))
                if let error = session.error { throw CLIError(code: "open_failed", message: error) }
                return .object(["libraryID": .optional(session.descriptor?.id), "seconds": .number(session.lastOpenSeconds), "reused": .bool(session.lastOpenReusedStore)])
            }
            if command == "import.pause" {
                guard store.isImporting else { throw CLIError(code: "no_import", message: "没有进行中的导入") }
                store.pauseImport(); await store.waitForImportCompletion()
                return .object(["paused": .bool(!store.isImporting), "resumable": .bool(store.resumableImport != nil)])
            }
            if command == "import.resume" {
                guard !store.isImporting, store.resumableImport != nil else { throw CLIError(code: "no_resumable_import", message: "没有可恢复的暂停任务") }
                store.resumeImport(); return .object(["started": .bool(store.isImporting)])
            }
            guard await store.undoEdit(redo: command == "edit.redo") else { throw CLIError(code: "edit_not_applied", message: store.toast ?? "整理历史不可用") }
            return .object(["committed": .bool(true), "canUndo": .bool(store.canUndoEdit), "canRedo": .bool(store.canRedoEdit)])
        }
        if command == "materials.list" {
            let limit = try boundedInt(args["limit"], fallback: 50, range: 1...200)
            let offset = try boundedInt(args["offset"], fallback: 0, range: 0...Int.max)
            let includeDeleted = args["includeDeleted"] ?? "false"
            guard ["true", "false"].contains(includeDeleted) else { throw CLIError(code: "invalid_argument", message: "includeDeleted必须为true或false") }
            if let kind = args["kind"], MaterialKind(rawValue: kind) == nil { throw CLIError(code: "invalid_argument", message: "kind必须是素材类型中文名称") }
            let query = args["query"] ?? ""
            let searchContext = MaterialSearchText.Context(fields: [.name, .note, .tags, .classification], links: [], folders: [], tagging: store.tagging)
            let matches = store.materials.filter { item in
                (includeDeleted == "true" || item.deletedAt == nil) &&
                (args["kind"] == nil || args["kind"] == item.kind.rawValue) &&
                (query.isEmpty || MaterialSearchText.normalized(item, fields: [.name, .note, .tags, .classification], context: searchContext).localizedCaseInsensitiveContains(query))
            }.sorted { $0.id < $1.id }
            let page = matches.dropFirst(min(offset, matches.count)).prefix(limit)
            return .object(["total": .number(Double(matches.count)), "offset": .number(Double(offset)), "limit": .number(Double(limit)),
                "items": .array(page.map { item in .object([
                    "id": .string(item.id), "name": .string(item.name), "kind": .string(item.kind.rawValue),
                    "tags": .array(item.tags.map(CLIValue.string)), "rating": .number(Double(item.rating)),
                    "classification": .string(item.classificationDisplayText),
                    "sourcePath": .optional(item.sourcePath), "deleted": .bool(item.deletedAt != nil)
                ]) })])
        }
        if command == "materials.show" {
            guard let id = args["id"], let item = store.materials.first(where: { $0.id == id }) else { throw CLIError(code: "not_found", message: "未找到素材ID") }
            return try .encoded(item)
        }
        if command.hasPrefix("browse.") {
            guard let navigation else { throw CLIError(code: "workspace_unavailable", message: "需要打开素材工作区窗口") }
            return try navigation(command, args)
        }
        let player = MaterialPlaybackController.shared
        guard player.currentMaterialID == session.browse.focused, let item = player.player.currentItem, item.status == .readyToPlay else {
            throw CLIError(code: "player_not_ready", message: "请先预览有效音视频，等待playback.status显示ready")
        }
        if let error = player.error { throw CLIError(code: "playback_failed", message: error) }
        if command == "playback.play" {
            if !player.playing { player.toggle() }
        } else if command == "playback.seek" {
            guard let raw = args["seconds"], let seconds = Double(raw), seconds.isFinite,
                  seconds >= 0, player.end > 0, seconds <= player.end else {
                throw CLIError(code: "invalid_argument", message: "seconds必须在当前媒体时长内且为有限数值")
            }
            player.seek(seconds)
        }
        return playbackState()
    }

    private func readyStore(_ session: LibrarySession) throws -> GlobalMaterialStore {
        guard !session.busy, let store = session.store, !store.isLoading else { throw CLIError(code: "library_not_ready", message: "资源库尚未就绪") }
        return store
    }
    private func boundedInt(_ raw: String?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw CLIError(code: "invalid_argument", message: "分页参数超出范围") }
        return value
    }
    private func playbackState() -> CLIValue {
        let player = MaterialPlaybackController.shared
        let item = player.player.currentItem
        return .object([
            "materialID": .optional(player.currentMaterialID), "playing": .bool(player.playing),
            "seconds": .number(player.time), "start": .number(player.start), "end": .number(player.end),
            "seeking": .bool(player.seeking), "scrubbing": .bool(player.scrubbing),
            "seekIssuedCount": .number(Double(player.seekIssuedCount)), "scrubCoalescedCount": .number(Double(player.scrubCoalescedCount)),
            "loop": .bool(player.loops), "error": .optional(player.error),
            "ready": .bool(item?.status == .readyToPlay), "hasItem": .bool(item != nil)
        ])
    }
}
