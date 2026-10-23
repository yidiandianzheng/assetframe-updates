import SwiftUI
import AppKit

struct CharacterProjectScanView: View {
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var library: CharacterLibraryStore
    @ObservedObject var materials: GlobalMaterialStore
    let onClose: () -> Void
    @State private var documents: [CharacterProjectDocument] = []
    @State private var checked: Set<String> = []
    @State private var filter = ""
    @State private var selectedPath: String?
    @State private var name = ""
    @State private var characterID = ""
    @State private var targetID = ""
    @State private var warnings: [String] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var settings = false
    @State private var prepared: Prepared?
    @State private var workflow = CharacterWorkflowBridge.Inventory()
    @State private var workflowID = ""
    @State private var changedOnly = true
    @State private var showFiles = false
    @EnvironmentObject private var editGuard: InspectorEditGuard
    struct Prepared {
        var profile: CharacterProfile
        var text: String
        var old: CharacterLibraryStore.Loaded?
        var path: URL
        var documents: [CharacterProjectDocument]
        var index: CharacterProjectModules.Index
        var indexHash: String?
    }
    private var root: URL { URL(fileURLWithPath: project.rootPath) }
    private var selected: [CharacterProjectDocument] { documents.filter { checked.contains($0.path) } }
    private var people: [CharacterLibraryStore.Loaded] { library.loaded.filter { $0.entry.projectID == project.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("项目资料整理 · \(project.name)").font(.title2.bold())
                Spacer()
                Button("关闭") { onClose() }.disabled(busy)
            }
            Text("沿用漫剧人物 ID 与资料入口。标准档案本地关联；旧 MD 按人物归组后交给 AI，核对候选再保存。").font(.caption)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
            if let prepared {
                Text("将保存：\(prepared.path.path)").font(.caption).textSelection(.enabled)
                if !warnings.isEmpty { DisclosureGroup("待核对与冲突：\(warnings.count) 项；冲突字段保留原值") { ScrollView { ForEach(Array(warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange) } }.frame(maxHeight: 100) } }
                HSplitView {
                    preview("原档案", prepared.old?.text ?? "新建标准档案，原资料保留")
                    preview("候选档案与引用", prepared.text)
                }
                HStack {
                    Button("返回核对") { self.prepared = nil }.disabled(busy)
                    Button("复制候选") { copy(prepared.text) }
                    Spacer()
                    Button("保存档案与模块索引") { save(prepared) }.disabled(busy || !materials.canWrite || !library.canEdit)
                }
            } else {
                HStack {
                    Button("扫描项目文件夹") { scan() }.disabled(busy)
                    Button("配置 AI…") { settings = true }.disabled(busy)
                    Button("发送所选文字给 AI 识别") { analyze() }.disabled(busy || selected.isEmpty)
                    if busy { ProgressView().controlSize(.small); Button("取消任务") { work?.cancel() } }
                    Spacer()
                    Text("勾选 \(selected.count) 份 · \(selected.reduce(0) { $0 + $1.text.utf8.count }) 字节").font(.caption)
                }
                HStack {
                    Picker("工作流人物", selection: $workflowID) {
                        Text("从现有人物接口／标准档案选择").tag("")
                        ForEach(workflow.people) { person in
                            Text("\(person.id) · \(person.name)\(person.conflict ? " · 姓名待核对" : "")").tag(person.id)
                        }
                    }.frame(maxWidth: 390)
                    Toggle("仅新增或变化资料", isOn: $changedOnly)
                    Button("选择该人物资料") { selectWorkflowPerson() }.disabled(workflowID.isEmpty)
                    Button("复制给 Codex 的交接") {
                        copy(CharacterWorkflowBridge.handoff(projectID: project.id, root: root, documents: selected, characterID: characterID, name: name))
                        notice = "已复制项目、人物、来源路径与指纹；可交给 Codex 续接，不包含 API Key。"
                    }.disabled(selected.isEmpty)
                }.disabled(busy)
                GroupBox("整理概览") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已读取 \(documents.count) 份 · 标准记录 \(documents.filter { CharacterWorkflowBridge.isStandard($0) }.count) 份 · 人物 \(workflow.people.count) 位")
                        if let report = library.reports[project.id] {
                            Text("新增 \(report.added) · 变化 \(report.changed) · 未读到 \(report.missing) · 提示 \(warnings.count)")
                            if report.navigationChanged { Text("入口或索引已变化，相关资料关联需要复核。").foregroundStyle(.orange) }
                            if !report.warnings.isEmpty { Text("读取或关联存在问题，结果可能不完整；已有记录保留。").foregroundStyle(.orange) }
                        }
                        Text("已整理 \(documents.filter { !$0.suggestions.isEmpty }.count) 份候选 · 已确认 \(people.flatMap { $0.receipts }.count) 条有效记录 · 已用于制作 \(materials.links.filter { $0.projectID == project.id }.count) 条引用")
                        Button(showFiles ? "收起资料明细" : "展开资料明细与核对") { showFiles.toggle() }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                if showFiles { HSplitView {
                    VStack(alignment: .leading) {
                        TextField("筛选人物或文件路径", text: $filter).textFieldStyle(.roundedBorder)
                        List(selection: $selectedPath) {
                            ForEach(documents.filter { filter.isEmpty || ($0.path + $0.name).localizedCaseInsensitiveContains(filter) }) { doc in
                                HStack(alignment: .top) {
                                    Toggle("选择", isOn: Binding(get: { checked.contains(doc.path) }, set: { if $0 { checked.insert(doc.path) } else { checked.remove(doc.path) } })).labelsHidden()
                                    VStack(alignment: .leading) {
                                        Text(doc.name.isEmpty ? doc.kind : "\(doc.name) · \(doc.kind)").font(.headline)
                                        Text(doc.path).font(.caption).lineLimit(2)
                                        Text(CharacterWorkflowBridge.isStandard(doc) ? "标准记录 · 本地读取" : (workflow.isUnchanged(doc, characterID: characterID) ? "已索引 · 内容未变" : "新增／变化／尚未索引")).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.tag(doc.path)
                            }
                        }
                    }.frame(minWidth: 280, idealWidth: 330)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("归入人物", selection: $targetID) {
                                Text("新建人物（核对稳定 ID）").tag("")
                                ForEach(people) { Text($0.profile?.name ?? $0.entry.characterID).tag($0.id) }
                            }
                            TextField("人物姓名（别名可稍后整理）", text: $name)
                            TextField("稳定人物 ID，例如 P-01", text: $characterID).disabled(!targetID.isEmpty)
                            Text("AI 提取仅填入空栏目；与已有内容不一致的字段列为冲突，不覆盖。视觉确认需标准记录及文件指纹通过；普通说明书保留依据供核对。").font(.caption)
                            Button("预览标准化档案与索引…") { prepare() }.disabled(busy || selected.isEmpty || characterID.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                            if let doc = documents.first(where: { $0.path == selectedPath }) {
                                Divider()
                                Text(doc.path).font(.headline).textSelection(.enabled)
                                Text(doc.warning).foregroundStyle(.orange)
                                if !doc.evidence.isEmpty { Text("原文线索：\(doc.evidence)").font(.caption).textSelection(.enabled) }
                                Button("用此人物名") { if !doc.name.isEmpty { name = doc.name } }.disabled(doc.name.isEmpty || !targetID.isEmpty)
                                Button("打开原文") { NSWorkspace.shared.open(CharacterProjectModules.resolve(doc.path, root: root)) }
                                if doc.text.contains(CharacterMarkdown.begin) {
                                    Button("直接关联标准人物档案") { attachStandard(doc) }.disabled(!materials.canWrite || !library.canEdit)
                                }
                                ForEach(CharacterProjectScanner.assetLinks(doc, root: root)) { link in
                                    VStack(alignment: .leading) {
                                        Text("关联素材：" + URL(fileURLWithPath: link.path).lastPathComponent).font(.caption.bold())
                                        Text(link.evidence).font(.caption).textSelection(.enabled)
                                        Text(FileManager.default.fileExists(atPath: link.path) ? "说明书引用待核对，不能据此自动确认" : "文件失联").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                ForEach(doc.suggestions) { suggestion in
                                    Text("\(suggestion.field)：\(suggestion.value)\n依据：\(suggestion.evidence)\n\(suggestion.conflict)").font(.caption).textSelection(.enabled)
                                }
                                DisclosureGroup("查看完整原文（也是发送内容）") { Text(doc.text).font(.caption).textSelection(.enabled) }
                            }
                            if !warnings.isEmpty { DisclosureGroup("扫描与冲突提示（\(warnings.count)）") { ForEach(Array(warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange) } } }
                        }.textFieldStyle(.roundedBorder).padding(8)
                    }.frame(minWidth: 410)
                }.disabled(busy) }
            }
        }.padding(20).frame(minWidth: 900, idealWidth: 1080, minHeight: 650, idealHeight: 760)
        .interactiveDismissDisabled()
        .onAppear { characterID = UUID().uuidString; editGuard.dirty = true; editGuard.save = nil; editGuard.discard = { onClose() }; scan() }
        .onDisappear { work?.cancel(); editGuard.dirty = false; editGuard.save = nil; editGuard.discard = nil }
        .onChange(of: targetID) { _, value in
            if let row = people.first(where: { $0.id == value }) { characterID = row.entry.characterID; name = row.profile?.name ?? "" }
            else if let person = workflow.people.first(where: { $0.id == workflowID }) { characterID = person.id; name = person.name }
            else { characterID = UUID().uuidString; name = "" }
        }
        .onChange(of: name) { _, _ in clearExtraction(); restoreCached() }
        .onChange(of: characterID) { _, _ in clearExtraction(); restoreCached() }
        .sheet(isPresented: $settings) {
            DeepSeekSettingsView(task: .characterOrganization, startsAfterSave: false, usageDescription: "每批最多 30 份、160 KB。只有点击发送后才上传选中的文字；可能产生 API 费用。", onSave: { _ in settings = false }, onCancel: { settings = false })
        }
    }
    private func preview(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(title).font(.headline); ScrollView { Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.frame(minWidth: 350)
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func clearExtraction() {
        // Shared MD candidates belong to the requested person, not to the file globally.
        for i in documents.indices where !documents[i].suggestions.isEmpty || documents[i].name != CharacterProjectScanner.nameHint(path: documents[i].path, text: documents[i].text) {
            documents[i].suggestions = []
            documents[i].evidence = ""
            documents[i].name = CharacterProjectScanner.nameHint(path: documents[i].path, text: documents[i].text)
            documents[i].kind = CharacterProjectScanner.classify(path: documents[i].path, text: documents[i].text)
            documents[i].warning = "目标人物已改变，请重新识别后核对。"
        }
    }
    private func selectWorkflowPerson() {
        guard let person = workflow.people.first(where: { $0.id == workflowID }) else { return }
        guard !person.conflict else { error = "同一 ID 有不同姓名，请先查看来源并核对；未自动归组。"; return }
        error = nil
        targetID = people.first(where: { $0.entry.characterID == person.id })?.id ?? ""
        characterID = person.id; name = person.name
        checked = CharacterWorkflowBridge.recommended(person, documents: documents, inventory: workflow, changedOnly: changedOnly)
        selectedPath = documents.first(where: { checked.contains($0.path) })?.path
        showFiles = true
        restoreCached()
        notice = "已按现有 ID 选择 \(checked.count) 份资料。候选／历史路径未自动勾选，可手动补选；归组不代表确认。"
    }
    private func attachStandard(_ doc: CharacterProjectDocument) {
        do {
            guard materials.canWrite, library.canEdit else { throw CharacterLibraryError.invalid("资源库当前不可写入") }
            try CharacterProjectScanner.verifyUnchanged([doc], root: root)
            guard let identity = try CharacterMarkdown.identity(doc.text), identity.projectID == project.id else { throw CharacterLibraryError.invalid("标准档案项目身份不同，未关联") }
            _ = try library.attach(CharacterProjectModules.resolve(doc.path, root: root), projectID: project.id, characterID: identity.characterID)
            busy = true; error = nil
            work = Task {
                defer { busy = false }
                await library.refresh()
                targetID = people.first(where: { $0.entry.characterID == identity.characterID })?.id ?? ""
                notice = "已直接关联原标准档案；未调用 AI，未复制或改写人物正文。"
            }
        } catch { self.error = error.localizedDescription }
    }
    private func scan() {
        guard materials.canWrite else { error = "资源库当前不可写入，已有资料保留。"; return }
        busy = true; error = nil
        work = Task {
            defer { busy = false }
            library.materialPaths = Dictionary(materials.materials.filter { $0.deletedAt == nil }.compactMap { m in m.fileLocation.map { ($0.url.resolvingSymlinksInPath().path, m.id) } }, uniquingKeysWith: { a, _ in a })
            await library.refreshSources(projectID: project.id)
            guard let report = library.reports[project.id] else { error = library.error; return }
            documents = report.documents
            workflow = CharacterWorkflowBridge.inventory(documents: documents, root: root, projectID: project.id)
            warnings = report.warnings + workflow.warnings
            checked = []; selectedPath = nil
            if workflow.people.count == 1 { workflowID = workflow.people[0].id; selectWorkflowPerson() }
            notice = "标准档案已本地关联；刷新未改写项目正文。选择人物即可集中核对其资料。"
        }
    }
    private func apply(_ result: [CharacterProjectScanner.Classification]) {
        for item in result {
            guard let i = documents.firstIndex(where: { $0.path == item.path }) else { continue }
            documents[i].name = item.name
            if !CharacterWorkflowBridge.sharedKinds.contains(documents[i].kind) { documents[i].kind = item.kind }
            documents[i].evidence = item.evidence
            documents[i].warning = item.conflict.isEmpty ? "已整理候选，核对后采纳；不是用户确认。" : item.conflict
            documents[i].suggestions = item.suggestions
        }
    }
    private func restoreCached() {
        let navigation = ProjectIntake.navigation(documents)
        let cached = documents.compactMap { library.intake.cached($0, projectID: project.id, characterID: characterID, name: name, navigation: navigation) }
        apply(cached)
    }
    private func analyze() {
        guard let config = DeepSeekAPISettings.storedConfiguration(for: .characterOrganization) else { error = "请先配置 AI 接口；本地读取仍可使用。"; return }
        let docs = selected.filter { !CharacterWorkflowBridge.isStandard($0) }
        guard !docs.isEmpty else { notice = "所选均为标准记录，无需 AI。"; return }
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines), requestedID = characterID
        guard !requestedName.isEmpty, !requestedID.isEmpty else { error = "请先选择工作流人物，避免跨人物提取。"; return }
        let navigation = ProjectIntake.navigation(documents)
        let navigationDocs = documents.filter { CharacterWorkflowBridge.sharedKinds.contains($0.kind) || $0.text.contains("assetframe-project-index:v1") }
        let cached = docs.compactMap { library.intake.cached($0, projectID: project.id, characterID: requestedID, name: requestedName, navigation: navigation) }
        let pending = docs.filter { doc in !cached.contains { $0.path == doc.path } }
        var batches: [[CharacterProjectDocument]] = [], batch: [CharacterProjectDocument] = [], bytes = 0
        for doc in pending {
            guard doc.text.utf8.count <= 160_000 else { error = "单份资料超过 AI 批次上限，请缩小选取：" + doc.path; return }
            if batch.count == 30 || bytes + doc.text.utf8.count > 160_000 { batches.append(batch); batch = []; bytes = 0 }
            batch.append(doc); bytes += doc.text.utf8.count
        }
        if !batch.isEmpty { batches.append(batch) }
        busy = true; error = nil
        work = Task {
            defer { busy = false }
            do {
                try CharacterProjectScanner.verifyUnchanged(docs + navigationDocs, root: root)
                apply(cached)
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    notice = "正在整理第 \(index + 1)/\(batches.count) 批；复用 \(cached.count) 份未变候选。"
                    let result = try await CharacterProjectScanner.analyze(batch, configuration: config, targetName: requestedName, characterID: requestedID)
                    try Task.checkCancellation()
                    try CharacterProjectScanner.verifyUnchanged(docs + navigationDocs, root: root)
                    var next = library.intake
                    next.record(result, documents: batch, projectID: project.id, characterID: requestedID, name: requestedName, navigation: navigation)
                    try library.saveIntake(next)
                    apply(result)
                }
                notice = "整理完成，复用 \(cached.count) 份候选；尚未写回项目正文。核对后可集中预览保存。"
            } catch { self.error = error.localizedDescription + "；已完成批次的候选保留，可重试剩余内容。" }
        }
    }
    private func prepare() {
        do {
            error = nil
            let docs = selected
            try CharacterProjectScanner.verifyUnchanged(docs, root: root)
            let old = people.first { $0.id == targetID }
            let id = characterID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard old != nil || !people.contains(where: { $0.entry.characterID == id }) else { throw CharacterLibraryError.invalid("此 ID 已存在，请在归入人物中选择现有记录。") }
            guard old == nil || old?.profile != nil else { throw CharacterLibraryError.missing }
            var profile = old?.profile ?? CharacterProfile(projectID: project.id, characterID: id)
            if old == nil { profile.fields["姓名"] = .init(text: name.trimmingCharacters(in: .whitespacesAndNewlines), review: .candidate, evidence: "用户核对扫描归组") }
            var conflicts: [String] = []
            for doc in docs {
                let absolute = CharacterProjectModules.resolve(doc.path, root: root).path
                if !profile.sources.contains(absolute) { profile.sources.append(absolute) }
                if let identity = try CharacterMarkdown.identity(doc.text) {
                    guard identity.projectID == project.id, identity.characterID == id else { throw CharacterLibraryError.invalid("\(doc.path) 的标准身份与目标不同，请关联到原人物；不要复制其身份。") }
                    if old == nil { throw CharacterLibraryError.invalid("发现标准人物档案，请关闭后使用“关联人物 MD”直接恢复原档案，避免另建正文。") }
                }
                if !doc.name.isEmpty && doc.name != name {
                    conflicts.append("\(doc.path)：人物名为 \(doc.name)，与目标 \(name) 不同，仅保留来源关联；旧名请人工核对。")
                    continue
                }
                if doc.kind == "确认记录" {
                    let receipt = try CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: doc.text, marker: "assetframe-confirmation")
                    guard old != nil else { throw CharacterLibraryError.invalid("此确认记录已有唯一人物档案，请先用“关联人物 MD”关联 \(receipt.profilePath)，再恢复记录。") }
                    guard receipt.characterID == id else { throw CharacterLibraryError.invalid("确认记录属于另一个人物，未串用") }
                    try CharacterProjectModules.verify(receipt, root: root, projectID: project.id)
                    let assetPath = CharacterProjectModules.resolve(receipt.assetPath, root: root).resolvingSymlinksInPath().path
                    if let material = materials.materials.first(where: { $0.deletedAt == nil && $0.fileLocation?.url.resolvingSymlinksInPath().path == assetPath }) {
                        if let position = profile.assets.firstIndex(where: { $0.materialID == material.id && $0.variant == receipt.variant && $0.role == receipt.role }) {
                            if profile.assets[position].status != receipt.status { conflicts.append("确认记录与现有资产状态不同，保留当前状态：" + receipt.assetPath) }
                        } else { profile.assets.append(.init(materialID: material.id, variant: receipt.variant, role: receipt.role, stage: receipt.stage, status: receipt.status)) }
                    } else { conflicts.append("确认文件已核验，但素材尚未入当前资源库，仅关联记录：" + receipt.assetPath) }
                } else if CharacterProjectScanner.classify(path: doc.path, text: doc.text) == "资产说明" && !doc.name.isEmpty {
                    for link in CharacterProjectScanner.assetLinks(doc, root: root) {
                        if let material = materials.materials.first(where: { $0.deletedAt == nil && $0.fileLocation?.url.resolvingSymlinksInPath().path == link.path }), !profile.assets.contains(where: { $0.materialID == material.id }) {
                            profile.assets.append(.init(materialID: material.id, variant: material.name, role: "补图", status: "候选"))
                        } else if !materials.materials.contains(where: { $0.fileLocation?.url.resolvingSymlinksInPath().path == link.path }) { conflicts.append("引用素材未入库或失联，保留原文链接：" + link.path) }
                    }
                }
                for suggestion in doc.suggestions {
                    if !suggestion.conflict.isEmpty { conflicts.append("\(suggestion.field)：\(suggestion.conflict)"); continue }
                    if let current = profile.fields[suggestion.field], !current.text.isEmpty {
                        if current.text != suggestion.value { conflicts.append("\(suggestion.field) 有不同内容，保留现值；来源 \(doc.path)") }
                    } else { profile.fields[suggestion.field] = .init(text: suggestion.value, review: .candidate, evidence: "\(absolute)\n\(suggestion.evidence)") }
                }
            }
            warnings += conflicts
            let key = CharacterMarkdown.fingerprint(Data((project.id + "|" + id).utf8)).prefix(24)
            let path = old.map { URL(fileURLWithPath: $0.entry.sourcePath) } ?? root.appendingPathComponent(CharacterProjectModules.directory + "/人物-\(key).md")
            let text = try CharacterMarkdown.render(profile, replacing: old?.text ?? "# 人物标准档案\n\n来源文件保留在关联资料中。候选栏目需核对，缺失内容待补充。\n")
            let (index, hash) = try CharacterProjectModules.readIndex(root: root, projectID: project.id)
            prepared = Prepared(profile: profile, text: text, old: old, path: path, documents: docs, index: index, indexHash: hash)
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ value: Prepared) {
        busy = true; error = nil
        work = Task {
            defer { busy = false }
            var savedPath: String?
            do {
                guard materials.canWrite, library.canEdit else { throw CharacterLibraryError.invalid("资源库当前不可写入") }
                try CharacterProjectScanner.verifyUnchanged(value.documents, root: root)
                for document in value.documents where document.kind == "确认记录" {
                    let receipt = try CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: document.text, marker: "assetframe-confirmation")
                    try CharacterProjectModules.verify(receipt, root: root, projectID: project.id)
                }
                let current = try CharacterProjectModules.readIndex(root: root, projectID: project.id)
                guard current.1 == value.indexHash else { throw CharacterLibraryError.conflict }
                if let old = value.old {
                    guard await library.save(profile: value.profile, loaded: old) else { throw CharacterLibraryError.invalid(library.error ?? "档案未保存") }
                } else {
                    try CharacterProjectModules.prepareDirectory(root: root)
                    try Data(value.text.utf8).write(to: value.path, options: .withoutOverwriting)
                    savedPath = value.path.path
                    _ = try library.attach(value.path, projectID: project.id, characterID: value.profile.characterID)
                }
                savedPath = value.path.path
                let refs = value.documents.map { CharacterProjectModules.Reference(characterID: value.profile.characterID, kind: $0.kind, path: $0.path, fingerprint: $0.fingerprint) } + [.init(characterID: value.profile.characterID, kind: "人物档案", path: CharacterProjectModules.relative(value.path, root: root), fingerprint: CharacterMarkdown.fingerprint(Data(value.text.utf8)))]
                try CharacterProjectModules.writeIndex(CharacterProjectModules.upsert(refs, into: value.index), root: root, expected: value.indexHash)
                await library.refresh(); prepared = nil
                workflow = CharacterWorkflowBridge.inventory(documents: documents, root: root, projectID: project.id)
                notice = "已保存人物档案与模块索引。原资料未修改；可返回人物库关闭“仅已确认资产”查看。"
            } catch { self.error = error.localizedDescription + (savedPath.map { "\n档案已保留：\($0)。若关联或索引失败，可用关联人物 MD 恢复；不要重复新建。" } ?? "") }
        }
    }
}
