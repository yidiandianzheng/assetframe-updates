import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CharacterLibraryView: View {
    @ObservedObject var materials: GlobalMaterialStore
    @StateObject private var library: CharacterLibraryStore
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var projectID = ""
    @State private var search = ""
    @State private var confirmedOnly = false
    @State private var selectedID: String?
    @State private var showProject = false
    @State private var projectAssets: CharacterLibraryRegistry.Project?
    @State private var scanning: CharacterLibraryRegistry.Project?
    @State private var confirming: CharacterLibraryStore.Loaded?
    struct Registration: Identifiable { let id = UUID(); var source: URL? }
    @State private var registrationRequest: Registration?
    @State private var characterID = ""
    @State private var characterName = ""
    @State private var registrationError: String?
    @State private var editing: CharacterLibraryStore.Loaded?
    @State private var usage: CharacterUsageSelection?
    private let root: URL

    init(root: URL, materials: GlobalMaterialStore) {
        self.root = root; self.materials = materials
        _library = StateObject(wrappedValue: CharacterLibraryStore(root: root))
    }
    private var rows: [CharacterLibraryStore.Loaded] {
        library.loaded.filter {
            (projectID.isEmpty || $0.entry.projectID == projectID) &&
            (!confirmedOnly || $0.profile?.hasConfirmedAsset == true) &&
            (search.isEmpty || $0.profile?.matches(search) == true || $0.entry.characterID.localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: CharacterLibraryStore.Loaded? { rows.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("人物库", systemImage: "person.text.rectangle").font(.headline)
                Picker("项目", selection: $projectID) {
                    Text("全部项目").tag("")
                    ForEach(library.registry.projects) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 240)
                TextField("搜索姓名、旧名、性格、说话特点…", text: $search).textFieldStyle(.roundedBorder)
                Toggle("仅已确认资产", isOn: $confirmedOnly).toggleStyle(.checkbox)
                Button("刷新", systemImage: "arrow.clockwise") { Task { await refreshProject() } }.disabled(library.busy)
            }.padding(12)
            HStack {
                Button("登记项目…", systemImage: "folder.badge.plus") { showProject = true }
                Button("项目资料整理…", systemImage: "sparkles") { scanning = library.registry.projects.first { $0.id == projectID } }.disabled(projectID.isEmpty)
                Button("项目资产与镜头…") { projectAssets = library.registry.projects.first { $0.id == projectID } }.disabled(projectID.isEmpty)
                Button("关联人物 MD…", systemImage: "link") { chooseMD() }.disabled(projectID.isEmpty)
                Button("新建人物…", systemImage: "person.badge.plus") {
                    characterID = UUID().uuidString; characterName = ""; registrationError = nil; registrationRequest = Registration(source: nil)
                }.disabled(projectID.isEmpty)
                Spacer()
                Text("MD 为准 · \(rows.count) 位人物").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.bottom, 10).disabled(!library.canEdit || !materials.canWrite)
            if let error = library.error {
                HStack { Text(error).foregroundStyle(.orange).textSelection(.enabled); Spacer(); Button("关闭提示") { library.error = nil } }.padding(8)
            }
            if let notice = library.notice { Text(notice).font(.caption).textSelection(.enabled).padding(6) }
            Divider()
            HSplitView {
                VStack {
                    if rows.isEmpty {
                        ContentUnavailableView("还没有匹配的人物", systemImage: "person.crop.rectangle.stack", description: Text(library.registry.projects.isEmpty ? "先登记项目，再关联已有 MD 或新建人物。" : "可关闭“仅已确认资产”查看待整理人物。"))
                    } else {
                        List(selection: $selectedID) {
                            ForEach(rows) { row in
                                HStack(alignment: .top, spacing: 10) {
                                    if let asset = row.profile?.assets.first(where: { $0.status == "已确认" && $0.role == "主图" }), let material = material(asset.materialID) {
                                        MaterialThumbnailView(material: material, showFormatBadge: false).frame(width: 52, height: 66)
                                    } else { Image(systemName: "person.crop.square").font(.largeTitle).foregroundStyle(.secondary).frame(width: 52, height: 66) }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.profile?.name ?? row.entry.characterID).font(.headline)
                                        Text(projectName(row.entry.projectID)).font(.caption).foregroundStyle(.secondary)
                                        Text(row.profile == nil ? "来源不可读" : (row.profile?.fields["一句话身份"]?.text.nonempty ?? "身份待补充")).lineLimit(2)
                                        Text(row.profile?.fields["正反派／阵营"]?.text.nonempty ?? "定位待补充").font(.caption)
                                        Text(row.profile?.hasConfirmedAsset == true ? "有已确认资产" : "待整理资产").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4).tag(row.id)
                            }
                        }
                    }
                }.frame(minWidth: 235, idealWidth: 280, maxWidth: 360)
                if let selected {
                    detail(selected).frame(minWidth: 390, maxWidth: .infinity)
                } else { ContentUnavailableView("选择一个人物", systemImage: "person.text.rectangle", description: Text("查看介绍、说话特点、剧情和当前资产。")) }
            }
        }
        .task { await refreshProject(); if library.registry.projects.count == 1 { projectID = library.registry.projects.first?.id ?? "" } }
        .sheet(isPresented: $showProject) {
            CharacterProjectEditor(existing: materials.organization.projects, onSave: { name, url, id in
                do {
                    var stableID = id
                    let indexURL = CharacterProjectModules.indexURL(root: url)
                    if FileManager.default.fileExists(atPath: indexURL.path) {
                        let index = try CharacterProjectModules.decode(CharacterProjectModules.Index.self, text: CharacterMarkdown.read(indexURL).0, marker: "assetframe-project-index")
                        guard index.version == 1, !index.projectID.isEmpty else { throw CharacterLibraryError.invalid("项目索引身份无效") }
                        stableID = index.projectID
                    }
                    projectID = try library.addProject(name: name, root: url, existingID: stableID); showProject = false
                    Task { await refreshProject(); scanning = library.registry.projects.first { $0.id == projectID } }
                }
                catch { library.error = error.localizedDescription }
            }, onCancel: { showProject = false })
        }
        .sheet(item: $projectAssets) { project in
            ProjectAssetWorkspace(project: project, library: library, materials: materials, onClose: { projectAssets = nil }).environmentObject(editGuard)
        }
        .sheet(item: $scanning) { project in
            CharacterProjectScanView(project: project, library: library, materials: materials, onClose: { scanning = nil; confirmedOnly = false }).environmentObject(editGuard)
        }
        .sheet(item: $confirming) { row in
            if let project = library.registry.projects.first(where: { $0.id == row.entry.projectID }) {
                CharacterConfirmationView(project: project, loaded: row, library: library, materials: materials, onClose: { confirming = nil }).environmentObject(editGuard)
            }
        }
        .sheet(item: $registrationRequest) { request in registration(request) }
        .sheet(item: $editing) { row in
            CharacterProfileEditor(library: library, materials: materials, loaded: row, onClose: { editing = nil })
                .environmentObject(editGuard)
        }
        .sheet(item: $usage) { selection in
            MaterialUsageEditor(store: materials, project: selection.project, draft: selection.draft, onClose: { usage = nil })
        }
    }
    private func refreshProject() async {
        guard materials.canWrite else { await library.refresh(); return }
        library.materialPaths = Dictionary(materials.materials.filter { $0.deletedAt == nil }.compactMap { m in m.fileLocation.map { ($0.url.resolvingSymlinksInPath().path, m.id) } }, uniquingKeysWith: { a, _ in a })
        await library.refreshSources(projectID: projectID.isEmpty ? nil : projectID)
    }
    private func material(_ id: String) -> MaterialRecord? { materials.materials.first { $0.id == id && $0.deletedAt == nil } }
    private func projectName(_ id: String) -> String { library.registry.projects.first { $0.id == id }?.name ?? id }
    private func detail(_ row: CharacterLibraryStore.Loaded) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.profile?.name ?? row.entry.characterID).font(.title2.bold())
                        Text("\(projectName(row.entry.projectID)) · \(row.entry.characterID)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开 MD") { openFile(row.entry.sourcePath) }
                    Button("记录资产确认…") { confirming = row }.disabled(row.profile == nil || !materials.canWrite || !library.canEdit)
                    Button("整理与编辑…") { editing = row }.disabled(row.profile == nil || !materials.canWrite || !library.canEdit)
                }
                if let error = row.error {
                    Text(error).foregroundStyle(.orange)
                    Button("重新定位 MD…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
                        if panel.runModal() == .OK, let url = panel.url {
                            do { try library.relocate(row.entry, to: url); Task { await library.refresh() } }
                            catch { library.error = error.localizedDescription }
                        }
                    }.disabled(!materials.canWrite || !library.canEdit)
                }
                if let profile = row.profile {
                    ForEach(CharacterProfile.groups, id: \.0) { group in
                        GroupBox(group.0) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(group.1, id: \.self) { key in
                                    let field = profile.fields[key] ?? .init()
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(key).font(.caption.bold())
                                            Text(field.text.isEmpty ? "待补充" : field.review.rawValue).font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            if group.0 == "生成模板" { Button("复制") { copy(field.text) }.disabled(field.text.isEmpty) }
                                        }
                                        Text(field.text.nonempty ?? "待补充").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        if !field.evidence.isEmpty { Text("依据：" + field.evidence).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    GroupBox("剧情记录") {
                        VStack(alignment: .leading, spacing: 10) {
                            if profile.stories.isEmpty { Text("待补充；正文与后续规划分别登记。").foregroundStyle(.secondary) }
                            ForEach(profile.stories) { story in
                                Text("\(story.episode) · \(story.state)").font(.headline)
                                Text(story.summary).textSelection(.enabled)
                                Button("打开剧情原文") { openReference(story.source, from: row.entry.sourcePath) }.disabled(story.source.isEmpty)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("人物资产") {
                        VStack(alignment: .leading, spacing: 12) {
                            if profile.assets.isEmpty { Text("尚未关联资产；在整理与编辑中从素材库选择。").foregroundStyle(.secondary) }
                            ForEach(profile.assets) { asset in assetRow(asset, profile: profile) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("有效制作与确认记录") {
                        VStack(alignment: .leading, spacing: 10) {
                            if row.receipts.isEmpty { Text("暂无通过文件核验的标准记录").foregroundStyle(.secondary) }
                            ForEach(row.receipts, id: \.id) { receipt in
                                Text("\(receipt.variant) · \(receipt.role) · \(receipt.stage)").font(.headline)
                                Text("确认依据：" + receipt.confirmationEvidence).textSelection(.enabled)
                                Text("原始生成提示词：" + (receipt.originalPrompt.isEmpty ? "待补充" : receipt.originalPrompt)).textSelection(.enabled)
                                Text("平台／模型：" + [receipt.platform, receipt.model].filter { !$0.isEmpty }.joined(separator: " / "))
                                Button("复制原始提示词") { copy(receipt.originalPrompt) }.disabled(receipt.originalPrompt.isEmpty)
                                ForEach(receipt.normalizedPrompt.keys.sorted(), id: \.self) { key in
                                    Text("复用模板 · \(key)：\(receipt.normalizedPrompt[key] ?? "")").textSelection(.enabled)
                                }
                            }
                            Button("为已核验文件建立原位索引") {
                                guard let project = library.registry.projects.first(where: { $0.id == row.entry.projectID }) else { return }
                                let root = URL(fileURLWithPath: project.rootPath)
                                let urls = row.receipts.map { CharacterProjectModules.resolve($0.assetPath, root: root) }
                                materials.importFiles(urls)
                                Task { await materials.waitForImportCompletion(); await refreshProject() }
                            }.disabled(row.receipts.isEmpty || !materials.canWrite)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("已用于制作") {
                        VStack(alignment: .leading) {
                            ForEach(materials.links.filter { link in link.projectID == profile.projectID && (link.subjectID == profile.characterID || profile.assets.contains(where: { a in a.materialID == link.materialID })) }) { link in
                                Text([link.episode, link.scene, link.shot].compactMap { $0 }.joined(separator: " / ") + " · " + (material(link.materialID)?.name ?? "素材缺失"))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("关联资料") {
                        VStack(alignment: .leading) {
                            ForEach(profile.sources, id: \.self) { source in Button(source) { openReference(source, from: row.entry.sourcePath) }.lineLimit(2) }
                            if profile.sources.isEmpty { Text("未添加其他资料").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup("原始 MD（保留全部历史说明）") {
                    Text(row.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }
    }
    private func assetRow(_ asset: CharacterProfile.Asset, profile: CharacterProfile) -> some View {
        HStack(alignment: .top) {
            if let item = material(asset.materialID) {
                MaterialThumbnailView(material: item).frame(width: 76, height: 90)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.headline)
                    Text("\(asset.variant) · \(asset.role) · \(asset.status)")
                    Text([asset.stage, asset.defaultUse].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption)
                    if item.sourceMissing { Text("源文件失联").foregroundStyle(.orange) }
                    HStack {
                        Button("预览／试听") { MaterialQuickLookController.shared.show(item) }.disabled(item.sourceMissing)
                        Button("定位") { if let url = item.fileLocation?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(item.sourceMissing)
                        Button("选用与交付…") { selectUsage(item, projectID: profile.projectID) }.disabled(item.sourceMissing || !materials.canWrite || asset.status != "已确认" || selected?.unavailableAssetIDs.contains(asset.materialID) == true)
                    }
                }
            } else {
                Label("素材记录缺失 · \(asset.variant) · \(asset.status)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
    private func selectUsage(_ item: MaterialRecord, projectID: String) {
        guard let project = library.registry.projects.first(where: { $0.id == projectID }) else { return }
        usage = CharacterUsageSelection(project: ProjectRecord(id: project.id, name: project.name, rootPath: project.rootPath, databasePath: "", isLegacy: false, lastOpenedAt: .now), draft: .init(materialID: item.id, subjectID: selected?.entry.characterID))
    }
    private func registration(_ request: Registration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.source == nil ? "新建人物 MD" : "关联现有 MD").font(.title2)
            Text("所属项目：\(projectName(projectID))")
            TextField("稳定人物 ID，例如 P-01", text: $characterID)
            if request.source == nil { TextField("人物姓名", text: $characterName) }
            else { Text(request.source?.path ?? "").font(.caption).textSelection(.enabled); Text("只建立关联；原文保留，未明确的信息不自动确认。").font(.caption) }
            if let registrationError { Text(registrationError).foregroundStyle(.orange) }
            HStack { Button("取消") { registrationRequest = nil }; Spacer(); Button("确定") { register(request) } }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 520).interactiveDismissDisabled()
    }
    private func chooseMD() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        characterID = UUID().uuidString; characterName = ""; registrationError = nil
        // Standard files already own their identity. Never generate a replacement ID.
        do {
            if let identity = try CharacterMarkdown.identity(CharacterMarkdown.read(url).0) {
                characterID = identity.characterID
                guard identity.projectID == projectID else { library.error = "此 MD 属于另一个项目。请在原项目关联；跨项目复用只引用素材，另建人物档案。"; return }
            }
        } catch { library.error = error.localizedDescription; return }
        registrationRequest = Registration(source: url)
    }
    private func register(_ request: Registration) {
        var createdFile: URL?
        do {
            guard materials.canWrite, library.canEdit else { throw CharacterLibraryError.invalid("资源库当前不可写入") }
            characterID = characterID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !characterID.isEmpty else { throw CharacterLibraryError.invalid("人物 ID 不能为空") }
            var url = request.source
            if url == nil {
                guard !characterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CharacterLibraryError.invalid("请输入人物姓名") }
                guard !library.registry.entries.contains(where: { $0.projectID == projectID && $0.characterID == characterID }) else { throw CharacterLibraryError.invalid("人物 ID 已存在") }
                let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = characterName + ".md"
                if let project = library.registry.projects.first(where: { $0.id == projectID }) { panel.directoryURL = URL(fileURLWithPath: project.rootPath) }
                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                var profile = CharacterProfile(projectID: projectID, characterID: characterID)
                profile.fields["姓名"] = .init(text: characterName, review: .confirmed)
                let text = try CharacterMarkdown.render(profile, replacing: "")
                try Data(text.utf8).write(to: chosen, options: .withoutOverwriting)
                url = chosen; createdFile = chosen
            }
            guard let url else { return }
            selectedID = try library.attach(url, projectID: projectID, characterID: characterID)
            confirmedOnly = false; registrationRequest = nil
            Task { await library.refresh() }
        } catch {
            registrationError = error.localizedDescription + (createdFile.map { "\n新 MD 已保留于：\($0.path)。可取消后通过“关联人物 MD”重试。" } ?? "")
        }
    }
    private func openFile(_ path: String) { if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) { library.error = "无法打开文件：\(path)" } }
    private func openReference(_ path: String, from source: String) {
        let raw = path.components(separatedBy: "#")[0]
        let base = URL(fileURLWithPath: source).deletingLastPathComponent()
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : base.appendingPathComponent(raw.removingPercentEncoding ?? raw)
        openFile(url.path)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct CharacterUsageSelection: Identifiable {
    var id = UUID()
    var project: ProjectRecord
    var draft: MaterialUsageDraft
}

extension String {
    fileprivate var nonempty: String? { isEmpty ? nil : self }
}
