import Foundation
import Combine

struct CharacterLibraryRegistry: Codable, Equatable, Sendable {
    struct Project: Identifiable, Codable, Equatable, Sendable {
        struct Source: Identifiable, Codable, Equatable, Sendable {
            var id: String
            var name: String
            var path: String
        }
        var id: String
        var name: String
        var rootPath: String
        var linkedSources: [Source]?
        var sources: [Source] {
            linkedSources ?? [.init(id: "primary", name: URL(fileURLWithPath: rootPath).lastPathComponent, path: rootPath)]
        }
    }
    struct Entry: Identifiable, Codable, Equatable, Sendable {
        var projectID: String
        var characterID: String
        var sourcePath: String
        var id: String { projectID + ":" + characterID }
    }
    var version = 1
    var projects: [Project] = []
    var entries: [Entry] = []
    func validate() throws {
        guard version == 1, Set(projects.map(\.id)).count == projects.count,
              Set(entries.map(\.id)).count == entries.count,
              projects.allSatisfy({ project in
                  let sources = project.sources
                  return Set(sources.map(\.id)).count == sources.count && Set(sources.map(\.path)).count == sources.count && sources.allSatisfy { !$0.id.isEmpty && !$0.path.isEmpty }
              }),
              entries.allSatisfy({ entry in projects.contains { $0.id == entry.projectID } }) else {
            throw CharacterLibraryError.invalid("人物库关联文件版本不支持或记录冲突，未重建覆盖")
        }
    }
}

@MainActor
final class CharacterLibraryStore: ObservableObject {
    struct Loaded: Identifiable, Sendable {
        var entry: CharacterLibraryRegistry.Entry
        var profile: CharacterProfile?
        var text = ""
        var fingerprint = ""
        var error: String?
        var receipts: [CharacterProjectModules.Receipt] = []
        var unavailableAssetIDs: Set<String> = []
        var id: String { entry.id }
    }
    @Published private(set) var registry = CharacterLibraryRegistry()
    @Published private(set) var loaded: [Loaded] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?
    struct ScanReport: Sendable {
        var documents: [CharacterProjectDocument]
        var warnings: [String]
        var added: Int
        var changed: Int
        var missing: Int
        var navigationChanged: Bool
    }
    @Published private(set) var reports: [String: ScanReport] = [:]
    @Published private(set) var intake = ProjectIntake()
    var materialPaths: [String: String] = [:]
    private var intakeHash: String?
    private var intakeValid = true
    private var intakeURL: URL { registryURL.deletingLastPathComponent().appendingPathComponent("project-intake.json") }
    private let registryURL: URL
    private var expectedRegistry: String?
    private var registryValid = true
    var canEdit: Bool { registryValid && !busy }
    init(root: URL) {
        registryURL = root.appendingPathComponent("character-library.json")
        do {
            if FileManager.default.fileExists(atPath: intakeURL.path) {
                let data = try Data(contentsOf: intakeURL)
                intake = try JSONDecoder().decode(ProjectIntake.self, from: data)
                guard intake.version == 1 else { throw CharacterLibraryError.invalid("资料读取缓存版本不支持") }
                intakeHash = CharacterMarkdown.fingerprint(data)
            }
        } catch { intakeValid = false; self.error = "资料读取缓存未覆盖：" + error.localizedDescription }
        do {
            if FileManager.default.fileExists(atPath: registryURL.path) {
                let data = try Data(contentsOf: registryURL)
                registry = try JSONDecoder().decode(CharacterLibraryRegistry.self, from: data)
                try registry.validate()
                expectedRegistry = CharacterMarkdown.fingerprint(data)
            }
        } catch { registryValid = false; self.error = error.localizedDescription }
    }
    private func commit(_ next: CharacterLibraryRegistry) throws {
        guard canEdit else { throw CharacterLibraryError.invalid("人物库正在读取或关联文件异常，暂不可写入") }
        try next.validate()
        let current = try FileManager.default.fileExists(atPath: registryURL.path) ? Data(contentsOf: registryURL) : nil
        guard current.map(CharacterMarkdown.fingerprint) == expectedRegistry else { throw CharacterLibraryError.conflict }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        if let current {
            try current.write(to: registryURL.deletingLastPathComponent().appendingPathComponent("character-library.previous.json"), options: .atomic)
        }
        try data.write(to: registryURL, options: .atomic)
        registry = next; expectedRegistry = CharacterMarkdown.fingerprint(data)
    }
    @discardableResult
    func addProject(name: String, root: URL, existingID: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CharacterLibraryError.invalid("请输入项目名称") }
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        if let old = registry.projects.first(where: { $0.rootPath == path }) { return old.id }
        let id = existingID ?? UUID().uuidString
        var next = registry
        next.projects.append(.init(id: id, name: name, rootPath: path))
        try commit(next); return id
    }
    func createProject(name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CharacterLibraryError.invalid("请输入项目名称") }
        let id = UUID().uuidString
        let metadata = registryURL.deletingLastPathComponent().appendingPathComponent("ProjectData/" + id)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var next = registry
        next.projects.append(.init(id: id, name: name, rootPath: metadata.path, linkedSources: []))
        try commit(next); return id
    }
    func linkSources(_ urls: [URL], projectID: String) throws {
        var next = registry
        guard let i = next.projects.firstIndex(where: { $0.id == projectID }) else { throw CharacterLibraryError.missing }
        var sources = next.projects[i].sources
        for url in urls {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw CharacterLibraryError.invalid("目录不可用：" + canonical.path)
            }
            if sources.contains(where: { $0.path == canonical.path }) { continue }
            sources.append(.init(id: UUID().uuidString, name: canonical.lastPathComponent, path: canonical.path))
        }
        next.projects[i].linkedSources = sources
        try commit(next)
    }
    func unlinkSource(_ sourceID: String, projectID: String) throws {
        var next = registry
        guard let i = next.projects.firstIndex(where: { $0.id == projectID }) else { throw CharacterLibraryError.missing }
        let removed = next.projects[i].sources.first { $0.id == sourceID }
        let remaining = next.projects[i].sources.filter { $0.id != sourceID }
        next.projects[i].linkedSources = remaining
        if let removed {
            next.entries.removeAll { entry in
                guard entry.projectID == projectID else { return false }
                let path = URL(fileURLWithPath: entry.sourcePath).resolvingSymlinksInPath().path
                return (path == removed.path || path.hasPrefix(removed.path + "/")) && !remaining.contains { path == $0.path || path.hasPrefix($0.path + "/") }
            }
        }
        try commit(next)
    }
    @discardableResult
    func attach(_ url: URL, projectID: String, characterID: String) throws -> String {
        guard !characterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CharacterLibraryError.invalid("人物 ID 不能为空") }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let (text, _) = try CharacterMarkdown.read(URL(fileURLWithPath: path))
        _ = try CharacterMarkdown.decode(text, projectID: projectID, characterID: characterID)
        if let old = registry.entries.first(where: { $0.projectID == projectID && $0.sourcePath == path }) { return old.id }
        let entry = CharacterLibraryRegistry.Entry(projectID: projectID, characterID: characterID, sourcePath: path)
        guard !registry.entries.contains(where: { $0.id == entry.id }) else { throw CharacterLibraryError.invalid("此项目已有人物 ID \(characterID)，请打开现有记录或使用重新定位") }
        var next = registry; next.entries.append(entry); try commit(next)
        return entry.id
    }
    func relocate(_ entry: CharacterLibraryRegistry.Entry, to url: URL) throws {
        let (text, _) = try CharacterMarkdown.read(url)
        _ = try CharacterMarkdown.decode(text, projectID: entry.projectID, characterID: entry.characterID)
        guard !registry.entries.contains(where: { $0.id != entry.id && $0.projectID == entry.projectID && $0.sourcePath == url.path }) else { throw CharacterLibraryError.invalid("此 MD 已关联另一个人物") }
        var next = registry
        guard let index = next.entries.firstIndex(where: { $0.id == entry.id }) else { throw CharacterLibraryError.missing }
        next.entries[index].sourcePath = url.resolvingSymlinksInPath().path
        try commit(next)
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let entries = registry.entries, projects = registry.projects, reports = reports, materialPaths = materialPaths
        let results = await Task.detached(priority: .userInitiated) {
            entries.map { entry -> Loaded in
                do {
                    let (text, hash) = try CharacterMarkdown.read(URL(fileURLWithPath: entry.sourcePath))
                    var profile = try CharacterMarkdown.decode(text, projectID: entry.projectID, characterID: entry.characterID)
                    var receipts: [CharacterProjectModules.Receipt] = [], issues: [String] = [], unavailable: Set<String> = []
                    if let project = projects.first(where: { $0.id == entry.projectID }) {
                        let root = URL(fileURLWithPath: project.rootPath)
                        for doc in reports[entry.projectID]?.documents ?? [] where doc.kind == "确认记录" {
                            do {
                                let receipt = try CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: doc.text, marker: "assetframe-confirmation")
                                guard receipt.characterID == entry.characterID else { continue }
                                try CharacterProjectScanner.verifyUnchanged([doc], root: root)
                                try CharacterProjectModules.verify(receipt, root: root, projectID: entry.projectID)
                                guard CharacterProjectModules.resolve(receipt.profilePath, root: root).resolvingSymlinksInPath().path == URL(fileURLWithPath: entry.sourcePath).resolvingSymlinksInPath().path else { throw CharacterLibraryError.invalid("确认记录引用了另一个档案") }
                                receipts.append(receipt)
                            } catch {
                                issues.append(doc.path + "：" + error.localizedDescription)
                                if let receipt = try? CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: doc.text, marker: "assetframe-confirmation"), receipt.characterID == entry.characterID {
                                    let path = CharacterProjectModules.resolve(receipt.assetPath, root: root).resolvingSymlinksInPath().path
                                    if let id = materialPaths[path] { unavailable.insert(id) }
                                }
                            }
                        }
                        let receiptGroups = Dictionary(grouping: receipts, by: \.id)
                        receipts = receiptGroups.keys.sorted().compactMap { id in
                            let group = receiptGroups[id]!
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                            let identities = Set(group.compactMap { try? encoder.encode($0) })
                            guard identities.count == 1 else {
                                issues.append("确认记录 ID 内容冲突：" + id)
                                for receipt in group {
                                    let path = CharacterProjectModules.resolve(receipt.assetPath, root: root).resolvingSymlinksInPath().path
                                    if let materialID = materialPaths[path] { unavailable.insert(materialID) }
                                }
                                return nil
                            }
                            return group.first
                        }
                        // Different receipts for the same file/use must not select a winner by scan order.
                        let groups = Dictionary(grouping: receipts) { $0.assetPath + "|" + $0.variant + "|" + $0.role + "|" + $0.stage }
                        for group in groups.values {
                            guard let receipt = group.first else { continue }
                            guard Set(group.map(\.status)).count == 1 else { issues.append("确认记录状态冲突：" + receipt.assetPath); continue }
                            let path = CharacterProjectModules.resolve(receipt.assetPath, root: root).resolvingSymlinksInPath().path
                            guard let materialID = materialPaths[path] else { continue }
                            if !profile.assets.contains(where: { $0.materialID == materialID && $0.variant == receipt.variant && $0.role == receipt.role && $0.stage == receipt.stage }) {
                                profile.assets.append(.init(id: "receipt-" + receipt.id, materialID: materialID, variant: receipt.variant, role: receipt.role, stage: receipt.stage, status: receipt.status))
                            }
                        }
                    }
                    return Loaded(entry: entry, profile: profile, text: text, fingerprint: hash, error: issues.isEmpty ? nil : issues.joined(separator: "\n"), receipts: receipts, unavailableAssetIDs: unavailable)
                } catch { return Loaded(entry: entry, error: error.localizedDescription) }
            }
        }.value
        loaded = results
    }
    func saveIntake(_ next: ProjectIntake) throws {
        guard intakeValid else { throw CharacterLibraryError.invalid("资料读取缓存损坏；保留原文件，未覆盖") }
        let current = try FileManager.default.fileExists(atPath: intakeURL.path) ? Data(contentsOf: intakeURL) : nil
        guard current.map(CharacterMarkdown.fingerprint) == intakeHash else { throw CharacterLibraryError.conflict }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: intakeURL, options: .atomic)
        intake = next; intakeHash = CharacterMarkdown.fingerprint(data)
    }
    func refreshSources(projectID: String? = nil) async {
        guard canEdit else { return }
        let projects = registry.projects.filter { projectID == nil || $0.id == projectID }
        for project in projects {
            busy = true
            let root = URL(fileURLWithPath: project.rootPath)
            let previous = reports[project.id]?.documents ?? []
            let task = Task.detached { Result { try CharacterProjectScanner.scan(project: project, previous: previous) } }
            let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            busy = false
            if Task.isCancelled { return }
            switch result {
            case .failure(let failure):
                error = "读取不完整，已有登记保留：" + failure.localizedDescription
                if reports[project.id] != nil { reports[project.id]?.warnings.append(error!) }
            case .success(let scan):
                let changes = intake.changes(projectID: project.id, documents: scan.documents)
                var issues = scan.warnings
                // Multiple standard files with the same identity need reconciliation, not first-match adoption.
                var candidates: [String: [CharacterProjectDocument]] = [:]
                for doc in scan.documents where doc.text.contains(CharacterMarkdown.begin) {
                    do {
                        guard let identity = try CharacterMarkdown.identity(doc.text), identity.projectID == project.id else { throw CharacterLibraryError.invalid("标准档案项目身份不匹配") }
                        candidates[identity.characterID, default: []].append(doc)
                    } catch { issues.append(doc.path + "：" + error.localizedDescription) }
                }
                for (id, docs) in candidates {
                    guard docs.count == 1, let doc = docs.first else { issues.append("同一人物 ID 有多个标准档案：" + id); continue }
                    do {
                        try CharacterProjectScanner.verifyUnchanged([doc], root: root)
                        if let existing = registry.entries.first(where: { $0.projectID == project.id && $0.characterID == id }) {
                            if URL(fileURLWithPath: existing.sourcePath).resolvingSymlinksInPath().path != CharacterProjectModules.resolve(doc.path, root: root).resolvingSymlinksInPath().path {
                                issues.append("档案路径变化，请核对后重新定位：" + id)
                            }
                        } else { _ = try attach(CharacterProjectModules.resolve(doc.path, root: root), projectID: project.id, characterID: id) }
                    } catch { issues.append(error.localizedDescription) }
                }
                reports[project.id] = ScanReport(documents: scan.documents, warnings: issues, added: changes.added, changed: changes.changed, missing: changes.missing, navigationChanged: changes.navigationChanged)
                var next = intake; next.observe(projectID: project.id, documents: scan.documents, complete: scan.warnings.isEmpty)
                do { try saveIntake(next) } catch { self.error = error.localizedDescription }
            }
        }
        await refresh()
    }
    func save(profile: CharacterProfile, loaded: Loaded) async -> Bool {
        guard canEdit else { error = "人物库当前不可写入"; return false }
        busy = true
        do {
            let text = try CharacterMarkdown.render(profile, replacing: loaded.text)
            let url = URL(fileURLWithPath: loaded.entry.sourcePath)
            let backup = try await Task.detached {
                try CharacterMarkdown.save(text, to: url, expected: loaded.fingerprint)
            }.value
            notice = "已写回 MD；备份：\(backup.lastPathComponent)"
            error = nil; busy = false
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; busy = false; return false }
    }
}
