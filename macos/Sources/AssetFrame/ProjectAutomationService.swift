import Foundation
import Combine

@MainActor
final class ProjectAutomationService: ObservableObject {
    typealias Analyzer = @Sendable (CharacterProjectDocument, ProjectAutomationState.Target?, DeepSeekConfiguration) async throws -> ProjectAutomationState.Extraction
    let library: CharacterLibraryStore
    let materials: GlobalMaterialStore
    @Published private(set) var state: ProjectAutomationState
    @Published private(set) var activity = ""
    @Published private(set) var error: String?
    @Published private(set) var connection = "未检查连接"
    @Published private(set) var resources: [String: [ProjectCatalogResource]] = [:]
    @Published private(set) var graphs: [String: ProjectAssetGraph] = [:]
    @Published private(set) var workbenches: [String: ProjectWorkbenchIndex] = [:]
    private var worker: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var monitor: LinkedFolderEventMonitor?
    private var rescan = false
    private var stopped = false
    private let analyzer: Analyzer
    private let configuration: () throws -> DeepSeekConfiguration
    private let eventMonitoring: Bool
    init(root: URL, materials: GlobalMaterialStore, eventMonitoring: Bool = true,
         configuration: @escaping () throws -> DeepSeekConfiguration = { try DeepSeekAPISettings.checkedConfiguration() },
         analyzer: @escaping Analyzer = { try await ProjectAutomationClient.analyze(document: $0, target: $1, configuration: $2) }) {
        library = CharacterLibraryStore(root: root); self.materials = materials
        state = library.intake.automation ?? ProjectAutomationState()
        self.configuration = configuration; self.analyzer = analyzer
        self.eventMonitoring = eventMonitoring
    }
    @discardableResult
    private func save(_ next: ProjectAutomationState) -> Bool {
        guard materials.canWrite else { error = "资源库不可写，整理进度保留且暂停"; return false }
        do {
            var intake = library.intake; intake.automation = next
            try library.saveIntake(intake); state = next; return true
        } catch { self.error = "整理进度保存失败，未继续请求：" + error.localizedDescription; return false }
    }
    @discardableResult
    func preserveWriteback(_ drafts: [ProjectAutomationState.WritebackDraft], project: String) -> Bool {
        var next = state
        if next.pendingWritebacks == nil { next.pendingWritebacks = [:] }
        next.pendingWritebacks?[project] = drafts
        return save(next)
    }
    func navigate(project: String, section: String, selection: String = "") {
        var next = state
        if next.navigation.projectID != project { next.navigation.episodeID = nil; next.navigation.documentPath = nil; next.navigation.search = ""; next.navigation.sourceFolder = nil }
        next.navigation.projectID = project; next.navigation.section = section; next.navigation.selectedID = selection
        _ = save(next)
    }
    func setSearch(_ search: String) { var next = state; next.navigation.search = search; _ = save(next) }
    func select(_ id: String) { var next = state; next.navigation.selectedID = id; _ = save(next) }
    func selectEpisode(_ id: String?) { var next = state; next.navigation.episodeID = id; next.navigation.selectedID = ""; next.navigation.documentPath = nil; next.navigation.sourceFolder = nil; _ = save(next) }
    func selectSourceFolder(_ path: String?) {
        var next = state; next.navigation.sourceFolder = path; next.navigation.episodeID = nil
        next.navigation.selectedID = ""; next.navigation.documentPath = nil
        _ = save(next)
    }
    func selectDocument(_ path: String) { var next = state; next.navigation.documentPath = path; _ = save(next) }
    func selectCategory(_ category: String) { var next = state; next.navigation.assetCategory = category; _ = save(next) }
    func assetDocumentPaths(projectID: String, target: String, kind: String) -> [String] {
        let target = kind == "生成提示词" ? URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.path : target
        return state.assetDocuments?[ProjectAutomationState.assetDocumentKey(projectID: projectID, target: target, kind: kind)]?.paths ?? []
    }
    func linkAssetDocument(_ url: URL, projectID: String, target: String, kind: String) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()), FileManager.default.isReadableFile(atPath: url.path),
              ["人物介绍", "生成提示词"].contains(kind), library.registry.projects.contains(where: { $0.id == projectID }) else {
            error = "请选择可读取的 MD 文件"; return
        }
        let target = kind == "生成提示词" ? URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.path : target
        var next = state
        if next.assetDocuments == nil { next.assetDocuments = [:] }
        let key = ProjectAutomationState.assetDocumentKey(projectID: projectID, target: target, kind: kind)
        var paths = next.assetDocuments?[key]?.paths ?? []
        if !paths.contains(url.path) { paths.append(url.path) }
        next.assetDocuments?[key] = .init(projectID: projectID, target: target, kind: kind, paths: paths)
        if save(next) { refresh() }
    }
    @discardableResult
    func preserveDocument(_ draft: ProjectAutomationState.WritebackDraft?, key: String) -> Bool {
        var next = state
        if next.documentDrafts == nil { next.documentDrafts = [:] }
        next.documentDrafts?[key] = draft
        return save(next)
    }
    private func indexWorkbench(_ project: CharacterLibraryRegistry.Project, documents: [CharacterProjectDocument], graph: ProjectAssetGraph) async {
        let people = library.loaded, resources = resources[project.id] ?? [], materials = materials.materials, links = self.materials.links, jobs = jobs(project: project.id)
        let oldFiles = workbenches[project.id]?.fileIndex ?? .init()
        let documentLinks = state.assetDocuments ?? [:]
        let index = await Task.detached(priority: .utility) {
            var index = ProjectWorkbenchIndex.build(projectID: project.id, root: URL(fileURLWithPath: project.rootPath), documents: documents,
                people: people, graph: graph, resources: resources, materials: materials, links: links, jobs: jobs, documentLinks: documentLinks)
            do { index.fileIndex = try ProjectSourceFileIndex.build(sources: project.sources, previous: oldFiles) }
            catch { index.fileIndex = oldFiles; index.fileIndex.warnings.append("文件树读取中断，保留上次结果") }
            return index
        }.value
        guard !Task.isCancelled else { return }
        workbenches[project.id] = index
    }
    func start() {
        stopped = false
        let previous = worker
        Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped else { return }
            var next = self.state; next.recoverInterrupted(); _ = self.save(next)
            self.restartMonitor()
        }
    }
    func waitUntilIdle() async { await worker?.value }
    func stop() {
        stopped = true; worker?.cancel(); watcher?.cancel(); monitor?.stop(); monitor = nil
    }
    func restartMonitor() {
        watcher?.cancel(); monitor?.stop()
        guard eventMonitoring else { monitor = nil; return }
        let monitor = LinkedFolderEventMonitor(roots: library.registry.projects.flatMap { $0.sources.map { URL(fileURLWithPath: $0.path) } })
        self.monitor = monitor
        watcher = Task { [weak self] in
            for await _ in monitor.events {
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    func refresh() {
        guard !stopped else { return }
        guard worker == nil else { rescan = true; return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.activity = "" }
            repeat {
                self.rescan = false
                await self.run()
            } while self.rescan && !Task.isCancelled && !self.stopped
        }
    }
    func enable(_ projectID: String, enabled: Bool) {
        var next = state
        // Persist the destination the user enabled; a different destination pauses requests.
        let endpoint = (try? configuration().baseURL) ?? DeepSeekAPISettings.configuredBaseURL
        next.permissions[projectID] = .init(enabled: enabled, endpoint: endpoint)
        if save(next) { refresh() }
    }
    func retry() {
        var next = state; next.haltReason = nil
        for id in next.jobs.keys where ["失败", "待重试"].contains(next.jobs[id]?.status ?? "") {
            next.jobs[id]?.status = "待整理"; next.jobs[id]?.issue = ""
        }
        if save(next) { error = nil; refresh() }
    }
    func register(name: String, root: URL, id: String?, automatic: Bool) throws {
        var stableID = id
        if FileManager.default.fileExists(atPath: CharacterProjectModules.indexURL(root: root).path) {
            stableID = try CharacterProjectModules.decode(CharacterProjectModules.Index.self, text: CharacterMarkdown.read(CharacterProjectModules.indexURL(root: root)).0, marker: "assetframe-project-index").projectID
        }
        if stableID == nil, FileManager.default.fileExists(atPath: ProjectAssetGraph.url(root: root).path) {
            stableID = try CharacterProjectModules.decode(ProjectAssetGraph.self, text: CharacterMarkdown.read(ProjectAssetGraph.url(root: root)).0, marker: ProjectAssetGraph.marker).projectID
        }
        let projectID = try library.addProject(name: name, root: root, existingID: stableID)
        navigate(project: projectID, section: "概览")
        if automatic { enable(projectID, enabled: true) }
        restartMonitor(); refresh()
    }
    func register(name: String, roots: [URL], id: String?, automatic: Bool) throws {
        let projectID: String
        if let id, library.registry.projects.contains(where: { $0.id == id }) {
            projectID = id
        } else if let first = roots.first, FileManager.default.fileExists(atPath: CharacterProjectModules.indexURL(root: first).path) || FileManager.default.fileExists(atPath: ProjectAssetGraph.url(root: first).path) {
            try register(name: name, root: first, id: id, automatic: false)
            projectID = state.navigation.projectID
        } else {
            projectID = try library.createProject(name: name)
        }
        if !roots.isEmpty { try library.linkSources(roots, projectID: projectID) }
        navigate(project: projectID, section: "概览")
        if automatic, !roots.isEmpty { enable(projectID, enabled: true) }
        restartMonitor(); refresh()
    }
    func linkSources(_ urls: [URL], projectID: String) throws {
        let before = library.registry.projects.first { $0.id == projectID }?.sources
        try library.linkSources(urls, projectID: projectID)
        guard before != library.registry.projects.first(where: { $0.id == projectID })?.sources else { refresh(); return }
        // A newly linked directory expands the sending scope; keep local reading available immediately.
        var next = state
        if next.permissions[projectID]?.enabled == true {
            next.permissions[projectID]?.enabled = false
            error = "已加入新目录并开始本地识别。自动整理已暂停，请在概览核对新的目录范围后开启。"
        }
        guard save(next) else { throw CharacterLibraryError.invalid("目录已保存，但整理状态保存失败，请刷新后核对") }
        restartMonitor(); refresh()
    }
    func unlinkSource(_ sourceID: String, projectID: String) throws {
        try library.unlinkSource(sourceID, projectID: projectID)
        selectSourceFolder(nil); restartMonitor(); refresh()
    }
    func jobs(project: String) -> [ProjectAutomationState.Job] {
        state.jobs.values.filter { $0.projectID == project && $0.active }.sorted { $0.path < $1.path }
    }
    func approve(_ job: ProjectAutomationState.Job, target: ProjectAutomationState.Target) {
        guard let project = library.registry.projects.first(where: { $0.id == job.projectID }),
              let doc = library.reports[job.projectID]?.documents.first(where: { $0.path == job.path }), doc.fingerprint == job.fingerprint else { error = "来源已变化，请刷新后核对"; return }
        do { try CharacterProjectScanner.verifyUnchanged([doc], root: URL(fileURLWithPath: project.rootPath)) }
        catch { self.error = error.localizedDescription; return }
        var next = state
        next.associations.removeAll { $0.projectID == job.projectID && $0.path == job.path && $0.target.id == target.id }
        next.associations.append(.init(projectID: job.projectID, path: job.path, target: target))
        // Identity changes require fresh targeted extraction, never relabel another person's fields.
        if job.target == target {
            next.jobs[job.id]?.approved = true; next.jobs[job.id]?.status = "已采用"; next.jobs[job.id]?.issue = ""
        }
        if save(next) { refresh() }
    }
    private func run() async {
        guard materials.canWrite else { error = "资源库不可写，自动整理暂停"; return }
        activity = "检查项目变化"
        library.materialPaths = Dictionary(materials.materials.filter { $0.deletedAt == nil }.compactMap { m in m.fileLocation.map { ($0.url.resolvingSymlinksInPath().path, m.id) } }, uniquingKeysWith: { a, _ in a })
        await library.refreshSources()
        guard !Task.isCancelled, !stopped else { return }
        for project in library.registry.projects {
            guard !Task.isCancelled else { return }
            guard let report = library.reports[project.id] else { continue }
            let root = URL(fileURLWithPath: project.rootPath)
            let graph: ProjectAssetGraph
            do { graph = try ProjectAssetGraph.read(root: root, projectID: project.id).0; graphs[project.id] = graph }
            catch { self.error = "项目资产读取失败：" + error.localizedDescription; continue }
            resources[project.id] = ProjectCatalogResource.read(documents: report.documents, root: root)
            let inventory = CharacterWorkflowBridge.inventory(documents: report.documents, root: root, projectID: project.id)
            let context = ProjectIntake.navigation(report.documents)
            var next = state
            // Unreadable documents stay visible as problems; they are never silently dropped.
            for id in next.jobs.keys where next.jobs[id]?.projectID == project.id { next.jobs[id]?.active = false }
            for doc in report.documents where !CharacterWorkflowBridge.isStandard(doc) {
                var targets: [ProjectAutomationState.Target] = inventory.people.filter { $0.paths.contains(doc.path) && !$0.conflict }.map { .init(id: $0.id, kind: "人物", name: $0.name) }
                for subject in graph.subjects where !subject.sourcePath.isEmpty && CharacterProjectModules.resolve(subject.sourcePath, root: root).standardizedFileURL == CharacterProjectModules.resolve(doc.path, root: root).standardizedFileURL {
                    targets.append(.init(id: subject.id, kind: subject.kind, name: subject.name))
                }
                if let declared = ProjectAutomationState.legacyAssetTarget(doc.text) { targets.append(declared) }
                targets += state.associations.filter { $0.projectID == project.id && $0.path == doc.path }.map(\.target)
                targets = Array(Set(targets)).sorted { $0.id < $1.id }
                let scopes: [ProjectAutomationState.Target?] = targets.isEmpty ? [nil] : targets.map { Optional($0) }
                for target in scopes {
                    let key = ProjectAutomationState.jobID(project: project.id, path: doc.path, fingerprint: doc.fingerprint, context: context, target: target)
                    if next.jobs[key] == nil {
                        next.jobs[key] = .init(id: key, projectID: project.id, path: doc.path, fingerprint: doc.fingerprint, context: context, target: target)
                    }
                    if next.jobs[key]?.target != target {
                        next.jobs[key]?.target = target; next.jobs[key]?.result = nil
                        next.jobs[key]?.status = "待整理"; next.jobs[key]?.approved = false
                    }
                    next.jobs[key]?.active = true
                    if doc.text.contains("status: 暂不启用") || doc.text.contains("document_type: 停用人物追溯卡") {
                        next.jobs[key]?.status = "待核对"; next.jobs[key]?.issue = "来源明确标为停用追溯；不自动整理为当前人物"
                    }
                }
            }
            let readable = Set(report.documents.map(\.path))
            for id in next.jobs.keys where next.jobs[id]?.projectID == project.id && !readable.contains(next.jobs[id]!.path) {
                let path = CharacterProjectModules.resolve(next.jobs[id]!.path, root: root).standardizedFileURL.path
                if !project.sources.contains(where: { ProjectSourceFileIndex.contains(path, in: $0.path) }) {
                    next.jobs[id]?.active = false
                    continue
                }
                next.jobs[id]?.active = true; next.jobs[id]?.status = "待核对"; next.jobs[id]?.issue = "来源失联或本次未完整读取，保留已有结果"
            }
            guard save(next) else { return }
            await indexWorkbench(project, documents: report.documents, graph: graph)
            guard let permission = state.permissions[project.id], permission.enabled else { continue }
            // No queued work means no credential access, even on frequent filesystem events.
            guard jobs(project: project.id).contains(where: { $0.status == "待整理" }) else { continue }
            let config: DeepSeekConfiguration
            do { config = try configuration(); connection = "已配置 · " + config.model }
            catch { connection = error.localizedDescription; self.error = connection; continue }
            guard permission.endpoint == config.baseURL else { self.error = "API 服务地址已改变，请在项目概览重新开启自动整理以核对发送范围"; continue }
            if let reason = state.haltReason { error = reason; continue }
            for job in jobs(project: project.id) where job.status == "待整理" {
                guard !Task.isCancelled, !stopped, state.permissions[project.id]?.enabled == true else { return }
                guard let doc = report.documents.first(where: { $0.path == job.path }), doc.text.utf8.count <= 160_000 else {
                    var next = state; next.jobs[job.id]?.status = "待核对"; next.jobs[job.id]?.issue = "来源不可读或超过单批 160 KB 上限"; guard save(next) else { return }; continue
                }
                do {
                    let dependencies = report.documents.filter { CharacterWorkflowBridge.sharedKinds.contains($0.kind) || CharacterWorkflowBridge.isStandard($0) }
                    try CharacterProjectScanner.verifyUnchanged([doc] + dependencies, root: root)
                    var next = state; next.jobs[job.id]?.status = "整理中"; guard save(next) else { return }
                    activity = "整理 · " + (job.target?.name ?? "待识别资料") + " · " + URL(fileURLWithPath: job.path).lastPathComponent
                    let result = try await analyzer(doc, job.target, config)
                    try Task.checkCancellation()
                    try CharacterProjectScanner.verifyUnchanged([doc] + dependencies, root: root)
                    var completed = state
                    completed.jobs[job.id]?.result = result
                    let issue = reviewIssue(result, job: job)
                    completed.jobs[job.id]?.issue = issue
                    completed.jobs[job.id]?.status = issue.isEmpty ? "整理完成" : "待核对"
                    if let target = job.target {
                        for id in completed.jobs.keys where id != job.id && completed.jobs[id]?.active == true && completed.jobs[id]?.projectID == project.id && completed.jobs[id]?.target?.id == target.id && completed.jobs[id]?.approved != true {
                            if let other = completed.jobs[id]?.result, other.fields.contains(where: { a in result.fields.contains { $0.name == a.name && $0.value != a.value } }) {
                                completed.jobs[id]?.status = "待核对"; completed.jobs[id]?.issue = "不同来源字段冲突；请核对两份依据"
                            }
                        }
                    }
                    guard save(completed) else { return }
                    connection = "连接正常 · " + config.model
                } catch {
                    if stopped || Task.isCancelled { return }
                    var failed = state; failed.jobs[job.id]?.status = "失败"; failed.jobs[job.id]?.issue = error.localizedDescription
                    let responseError = error as? DeepSeekClientError
                    if error is URLError || (responseError != nil && responseError != .invalidJSON && responseError != .emptyContent && responseError != .outputLimit) {
                        failed.haltReason = error.localizedDescription + "；自动请求已暂停，修复后点击重试"
                    }
                    guard save(failed) else { return }
                    self.error = error.localizedDescription
                    // Do not repeatedly charge for failed requests on every filesystem event.
                    if state.haltReason != nil { await indexWorkbench(project, documents: report.documents, graph: graph); return }
                }
            }
            await indexWorkbench(project, documents: report.documents, graph: graph)
        }
    }
    private func reviewIssue(_ result: ProjectAutomationState.Extraction, job: ProjectAutomationState.Job) -> String {
        guard let target = job.target else { return "主体身份待核对；AI 只提出名称建议" }
        if !result.conflict.isEmpty { return result.conflict }
        if CharacterWorkflowBridge.isHistoricalHint(job.path) { return "历史或候选资料，不能自动当作当前设定" }
        if let person = library.loaded.first(where: { $0.entry.projectID == job.projectID && $0.entry.characterID == target.id }), let profile = person.profile {
            for field in result.fields {
                if let existing = profile.fields[field.name]?.text, !existing.isEmpty, existing != field.value { return "与现有档案字段不同：" + field.name }
            }
        }
        let peers = jobs(project: job.projectID).filter { $0.target?.id == target.id && $0.id != job.id && $0.result != nil }
        for field in result.fields where peers.contains(where: { $0.result?.fields.contains { $0.name == field.name && $0.value != field.value } == true }) { return "不同来源字段冲突：" + field.name }
        return ""
    }
}
