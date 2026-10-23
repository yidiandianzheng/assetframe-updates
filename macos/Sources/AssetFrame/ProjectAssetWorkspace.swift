import SwiftUI
import AppKit

/// A local editor for portable project relationships. No generation service is invoked.
struct ProjectAssetWorkspace: View {
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var library: CharacterLibraryStore
    @ObservedObject var materials: GlobalMaterialStore
    let onClose: () -> Void
    let embedded: Bool
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var graph: ProjectAssetGraph
    @State private var expected: String?
    @State private var loadValid = false
    @State private var subjectID = ""
    @State private var category = "人物"
    @State private var selectedAssetID = ""
    @State private var selectedShotID = ""
    @State private var selectedUsages: Set<String> = []
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var editor = ""
    @State private var editingSubjectID: String?
    @State private var title = ""
    @State private var detail = ""
    @State private var source = ""
    @State private var stage = ""
    @State private var episode = ""
    @State private var scene = ""
    @State private var variantID = ""
    @State private var materialID = ""
    @State private var materialQuery = ""
    @State private var pendingCharacter: CharacterProfile?
    @State private var pendingCharacterSource: CharacterLibraryStore.Loaded?
    @State private var role = "主图"
    @State private var evidence = ""
    @State private var prompt = ""
    @State private var reuse = ""
    @State private var platform = ""
    @State private var model = ""
    @State private var references = ""
    @State private var confirmed = false
    @State private var costumes: Set<String> = []
    @State private var props: Set<String> = []
    @State private var pending: ProjectAssetGraph?
    @State private var pendingDescription = ""
    init(project: CharacterLibraryRegistry.Project, library: CharacterLibraryStore, materials: GlobalMaterialStore, category: String = "人物", embedded: Bool = false, onClose: @escaping () -> Void) {
        self.embedded = embedded; _category = State(initialValue: category)
        self.project = project; self.library = library; self.materials = materials; self.onClose = onClose
        _graph = State(initialValue: ProjectAssetGraph(projectID: project.id))
    }
    private var root: URL { URL(fileURLWithPath: project.rootPath) }
    private var characters: [CharacterLibraryStore.Loaded] { library.loaded.filter { $0.entry.projectID == project.id } }
    private var characterIDs: Set<String> { Set(characters.map { $0.entry.characterID }) }
    private var subjects: [ProjectAssetGraph.Subject] {
        graph.subjects + characters.map { .init(id: $0.entry.characterID, kind: "人物", name: $0.profile?.name ?? $0.entry.characterID, sourcePath: $0.entry.sourcePath) }
    }
    private var variants: [ProjectAssetGraph.Variant] { graph.variants.filter { $0.subjectID == subjectID } }
    private var assets: [ProjectAssetGraph.Asset] { graph.assets.filter { $0.subjectID == subjectID } }
    private var selectedAsset: ProjectAssetGraph.Asset? { assets.first { $0.id == selectedAssetID } }
    private var usages: [ProjectMaterialLink] {
        let legacyIDs = Set(characters.first { $0.entry.characterID == subjectID }?.profile?.assets.map(\.materialID) ?? [])
        return materials.links.filter { $0.projectID == project.id && ($0.subjectID == subjectID || legacyIDs.contains($0.materialID)) }
    }
    private var availableMaterials: [MaterialRecord] { materials.materials.filter { $0.deletedAt == nil } }
    private var materialChoices: [MaterialRecord] {
        let matches = availableMaterials.filter { materialQuery.isEmpty || ($0.name + $0.id).localizedCaseInsensitiveContains(materialQuery) }
        var items = Array(matches.prefix(60))
        if let chosen = availableMaterials.first(where: { $0.id == materialID }), !items.contains(where: { $0.id == chosen.id }) { items.append(chosen) }
        return items
    }
    private func currentStatus(_ asset: ProjectAssetGraph.Asset) -> String {
        if let person = characters.first(where: { $0.entry.characterID == asset.subjectID }), let materialID = material(for: asset)?.id {
            if person.unavailableAssetIDs.contains(materialID) { return "文件待核验" }
            if let current = person.profile?.assets.first(where: { $0.materialID == materialID && $0.stage == asset.stage && $0.role == asset.role }) { return current.status }
        }
        return asset.status
    }
    private func isDefault(_ asset: ProjectAssetGraph.Asset) -> Bool {
        if let person = characters.first(where: { $0.entry.characterID == asset.subjectID }) {
            return person.profile?.assets.contains { $0.materialID == material(for: asset)?.id && $0.stage == asset.stage && $0.role == asset.role && $0.status == "已确认" && !$0.defaultUse.isEmpty } == true
        }
        return asset.isDefault
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目资产 · " + project.name).font(.title2.bold())
                Spacer()
                Button("刷新") { load() }.disabled(busy || !editor.isEmpty)
                Button(embedded ? "返回资料" : "关闭", action: onClose).disabled(busy)
            }
            Picker("分类", selection: $category) { ForEach(ProjectAssetGraph.kinds, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            HStack {
                Text("主体")
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(subjects.filter { $0.kind == category }) { subject in
                            Button(subject.name) { subjectID = subject.id }
                                .tint(subject.id == subjectID ? Color.accentColor : Color.secondary)
                        }
                    }
                }.frame(maxWidth: 360)
                if category != "人物" {
                    Button("新增" + category) { openEditor("主体") }
                    Button("编辑资料") { openEditor("编辑主体") }.disabled(subjectID.isEmpty)
                }
                Button("新增造型／状态") { openEditor("造型") }.disabled(subjectID.isEmpty)
                Button("关联素材版本") { openEditor("素材") }.disabled(variants.isEmpty)
                Button("登记镜头") { openEditor("镜头") }
                Button("索引已确认文件") { indexConfirmedFiles() }
            }.disabled(!loadValid || busy || !materials.canWrite)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let notice { Text(notice).font(.caption).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let subject = subjects.first(where: { $0.id == subjectID }) {
                            Text(subject.name).font(.title2)
                            if !subject.description.isEmpty { Text(subject.description).textSelection(.enabled) }
                            if !subject.sourcePath.isEmpty { Button("打开主体原文") { NSWorkspace.shared.open(CharacterProjectModules.resolve(subject.sourcePath, root: root)) } }
                        }
                        ForEach(variants) { variant in
                            GroupBox(variant.name + " · " + variant.stage) {
                                VStack(alignment: .leading) {
                                    Text(variant.fixedFeatures).textSelection(.enabled)
                                    Text("服装：" + names(variant.costumeIDs))
                                    Text("道具：" + names(variant.propIDs))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let person = characters.first(where: { $0.entry.characterID == subjectID }), let profile = person.profile, !profile.assets.isEmpty {
                            GroupBox("现有人物档案引用（原 MD 为准）") {
                                VStack(alignment: .leading) {
                                    ForEach(profile.assets) { asset in
                                        Text("\(asset.variant) · \(asset.role) · \(asset.status)")
                                        Text(materials.materials.first { $0.id == asset.materialID }?.name ?? "素材尚未入库").font(.caption)
                                    }
                                    Text("关联素材时可自动带入有效确认记录；无需重填确认依据。").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(assets) { asset in
                            Button { selectedAssetID = asset.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text((isDefault(asset) ? "当前默认 · " : "") + asset.role + " · " + asset.status).font(.headline)
                                    Text(URL(fileURLWithPath: asset.path).lastPathComponent)
                                    Text(asset.stage).font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(selectedAssetID == asset.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                            }.buttonStyle(.plain)
                        }
                    }.padding(8)
                }.frame(minWidth: 280, idealWidth: 330)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let asset = selectedAsset {
                            assetDetail(asset)
                        } else { Text("选择一个具体素材版本，查看记录、取用或检查镜头影响。").foregroundStyle(.secondary) }
                        Divider()
                        Text("镜头使用与版本影响").font(.headline)
                        Text("切换默认版本不会修改下列引用。勾选镜头后才更新其使用版本。").font(.caption)
                        ForEach(usages) { link in
                            Toggle(isOn: Binding(get: { selectedUsages.contains(link.id) }, set: { if $0 { selectedUsages.insert(link.id) } else { selectedUsages.remove(link.id) } })) {
                                VStack(alignment: .leading) {
                                    Text([link.episode, link.scene, link.shot].compactMap { $0 }.joined(separator: " / "))
                                    Text("固定素材：" + (materials.materials.first { $0.id == link.materialID }?.name ?? link.materialID)).font(.caption)
                                    Text("历史更换 \(link.previousVersions?.count ?? 0) 次").font(.caption)
                                    if let path = link.sourceDocument { Button("打开分镜来源") { NSWorkspace.shared.open(CharacterProjectModules.resolve(path, root: root)) } }
                                }
                            }
                        }
                        Button("将勾选镜头更新为选中版本…") {
                            notice = "将更新 \(selectedUsages.count) 条镜头引用；旧版本会保留在历史中。"
                            editor = "更新引用"
                        }.disabled(selectedUsages.isEmpty || selectedAsset.map { currentStatus($0) } != "已确认" || busy || !loadValid)
                        Button("导出本项目已选用素材…") { export() }.disabled(busy || !loadValid || !materials.canWrite)
                    }.padding(12)
                }.frame(minWidth: 430)
            }
        }.padding(20).frame(minWidth: embedded ? 760 : 1000, minHeight: embedded ? 500 : 740)
            .task { load() }
            .onChange(of: category) { _, _ in subjectID = ""; selectSingleSubject(); selectedUsages = [] }
            .onChange(of: subjectID) { _, _ in selectedAssetID = assets.first(where: { isDefault($0) })?.id ?? assets.first?.id ?? ""; selectedUsages = [] }
            .sheet(isPresented: Binding(get: { !editor.isEmpty }, set: { if !$0 { editor = "" } })) { editorView }
    }
    private func names(_ ids: [String]) -> String { ids.compactMap { id in subjects.first { $0.id == id }?.name }.joined(separator: "、") }
    private func assetDetail(_ asset: ProjectAssetGraph.Asset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(asset.role + " · " + currentStatus(asset)).font(.title3.bold())
            Text(asset.path).font(.caption).textSelection(.enabled)
            Text("确认依据：" + (asset.evidence.isEmpty ? "待补充" : asset.evidence)).textSelection(.enabled)
            Text("原始生成提示词\n" + (asset.originalPrompt.isEmpty ? "待补充" : asset.originalPrompt)).textSelection(.enabled)
            Text("标准化复用模板\n" + (asset.reuseTemplate.isEmpty ? "待补充" : asset.reuseTemplate)).textSelection(.enabled)
            Text("\(asset.platform) / \(asset.model)").font(.caption)
            Text("选用和导出时核验具体文件指纹；确认不等于技术 QA 通过。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("预览") { if let item = material(for: asset) { MaterialQuickLookController.shared.show(item) } }
                Button("复制制作交接") { copy(handoff(asset)) }
                Button("设为当前默认…") { previewDefault(asset) }.disabled(currentStatus(asset) != "已确认" || !loadValid || busy)
                Button("确认／停用…") { openEditor("状态"); confirmed = asset.status != "已确认" }
            }
            DisclosureGroup("制作与状态记录") {
                ForEach(graph.events.filter { $0.assetID == asset.id }) { event in
                    Text(event.date.formatted() + " · " + event.action + "\n" + event.evidence).font(.caption).textSelection(.enabled)
                }
            }
            Picker("选用镜头", selection: $selectedShotID) {
                Text("选择已登记镜头").tag("")
                ForEach(graph.shots) { Text([$0.episode, $0.scene, $0.name].filter { !$0.isEmpty }.joined(separator: " / ")).tag($0.id) }
            }
            Button("为此镜头选用当前版本") { use(asset) }.disabled(currentStatus(asset) != "已确认" || selectedShotID.isEmpty || busy || !loadValid || !materials.canWrite)
        }
    }
    private var editorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor).font(.title2)
            if editor == "更新引用" {
                Text("将明确选中的 \(selectedUsages.count) 条镜头引用更新为当前选中素材；每条旧引用保留历史。")
                HStack { Button("取消") { editor = "" }; Button("确认更新") { replaceUsages() }.disabled(busy) }
            } else if let pending {
                Text(pendingDescription).textSelection(.enabled)
                DisclosureGroup("查看将保存的标准记录") { ScrollView { Text((try? CharacterProjectModules.encode(pending, marker: ProjectAssetGraph.marker, title: "项目资产")) ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 300) }
                Button("复制候选记录") { copy((try? CharacterProjectModules.encode(pending, marker: ProjectAssetGraph.marker, title: "项目资产")) ?? "") }
                HStack { Button("返回编辑") { self.pending = nil }; Spacer(); Button("保存记录") { save(pending) }.disabled(busy || !materials.canWrite) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if editor == "主体" || editor == "编辑主体" {
                            TextField("名称", text: $title)
                            TextField("描述", text: $detail, axis: .vertical)
                            TextField("来源 MD 路径（可选）", text: $source)
                        } else if editor == "造型" {
                            TextField("造型／状态名称", text: $title)
                            TextField("适用阶段", text: $stage)
                            TextField("固定特征", text: $detail, axis: .vertical)
                            ForEach(graph.subjects.filter { $0.kind == "服装" }) { item in
                                Toggle("服装 · " + item.name, isOn: Binding(get: { costumes.contains(item.id) }, set: { if $0 { costumes.insert(item.id) } else { costumes.remove(item.id) } }))
                            }
                            ForEach(graph.subjects.filter { $0.kind == "道具" }) { item in
                                Toggle("道具 · " + item.name, isOn: Binding(get: { props.contains(item.id) }, set: { if $0 { props.insert(item.id) } else { props.remove(item.id) } }))
                            }
                        } else if editor == "素材" {
                            Picker("造型", selection: $variantID) { ForEach(variants) { Text($0.name).tag($0.id) } }
                            TextField("搜索素材名称或 ID（最多显示 60 项）", text: $materialQuery)
                            Picker("已有素材", selection: $materialID) {
                                Text("选择素材").tag("")
                                ForEach(materialChoices) { Text($0.name).tag($0.id) }
                            }.onChange(of: materialID) { _, _ in fillProvenance() }
                            TextField("用途，例如主图、身形参考、声线", text: $role)
                            TextField("适用阶段", text: $stage)
                            Toggle("此次明确确认为可用资产", isOn: $confirmed)
                            TextField("确认依据（确认时必填）", text: $evidence, axis: .vertical)
                            TextField("实际生成原始提示词（未知留空）", text: $prompt, axis: .vertical)
                            TextField("标准化复用模板", text: $reuse, axis: .vertical)
                            TextField("平台", text: $platform); TextField("模型", text: $model)
                            TextField("参考素材路径（每行一项）", text: $references, axis: .vertical)
                        } else if editor == "镜头" {
                            TextField("集数", text: $episode); TextField("场次", text: $scene)
                            TextField("镜头名称／编号", text: $title)
                            TextField("分镜 MD 路径（可选）", text: $source)
                        } else if editor == "状态" {
                            Toggle("确认可用（关闭则记为历史停用）", isOn: $confirmed)
                            TextField("本次依据", text: $evidence, axis: .vertical)
                        }
                    }
                }.frame(maxHeight: 420)
                HStack { Button("取消") { editor = "" }; Spacer(); Button("预览保存") { prepare() }.disabled(busy) }
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 640).interactiveDismissDisabled()
            .onAppear { editGuard.dirty = true; editGuard.save = nil; editGuard.discard = { editor = "" } }
            .onDisappear { editGuard.dirty = false; editGuard.save = nil; editGuard.discard = nil }
    }
    private func load() {
        do {
            let result = try ProjectAssetGraph.read(root: root, projectID: project.id)
            try result.0.validate(characterIDs: characterIDs)
            graph = result.0; expected = result.1; loadValid = true; error = nil
            selectSingleSubject()
            if graph.shots.count == 1 { selectedShotID = graph.shots[0].id }
        } catch { loadValid = false; self.error = "已有记录保留，暂不可写入：" + error.localizedDescription }
    }
    private func selectSingleSubject() {
        let choices = subjects.filter { $0.kind == category }
        if !choices.contains(where: { $0.id == subjectID }), choices.count == 1 { subjectID = choices[0].id }
    }
    private func openEditor(_ kind: String) {
        editor = kind; pending = nil; pendingCharacter = nil; pendingCharacterSource = nil; error = nil; notice = nil
        title = ""; detail = ""; source = ""; stage = ""; evidence = ""; prompt = ""; reuse = ""; platform = ""; model = ""; references = ""
        variantID = variants.first?.id ?? ""; materialID = ""; confirmed = false; costumes = []; props = []; editingSubjectID = nil
        if kind == "编辑主体", let subject = graph.subjects.first(where: { $0.id == subjectID }) { editingSubjectID = subject.id; title = subject.name; detail = subject.description; source = subject.sourcePath }
    }
    private func fillProvenance() {
        guard let item = availableMaterials.first(where: { $0.id == materialID }) else { return }
        prompt = item.production?.prompt ?? ""; platform = item.production?.platform ?? ""; model = item.production?.model ?? ""
        evidence = ""; reuse = ""; confirmed = false
        if let receipt = characters.first(where: { $0.entry.characterID == subjectID })?.receipts.first(where: { CharacterProjectModules.resolve($0.assetPath, root: root).resolvingSymlinksInPath().path == item.fileLocation?.url.resolvingSymlinksInPath().path }) {
            evidence = receipt.confirmationEvidence; prompt = receipt.originalPrompt; platform = receipt.platform; model = receipt.model
            reuse = receipt.normalizedPrompt.sorted { $0.key < $1.key }.map { $0.key + "：" + $0.value }.joined(separator: "\n")
            role = receipt.role; stage = receipt.stage
            let existing = characters.first { $0.entry.characterID == subjectID }?.profile?.assets.first { $0.materialID == item.id && $0.role == receipt.role && $0.variant == receipt.variant && $0.stage == receipt.stage }
            confirmed = receipt.status == "已确认" && (existing == nil || existing?.status == "已确认")
        }
    }
    private func prepare() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                var next = graph
                switch editor {
                case "主体", "编辑主体":
                    let subject = ProjectAssetGraph.Subject(id: editingSubjectID ?? UUID().uuidString, kind: category, name: title.trimmingCharacters(in: .whitespacesAndNewlines), description: detail, sourcePath: source)
                    if let i = next.subjects.firstIndex(where: { $0.id == subject.id }) { next.subjects[i] = subject } else { next.subjects.append(subject) }
                case "造型":
                    next.variants.append(.init(subjectID: subjectID, name: title, stage: stage, fixedFeatures: detail, costumeIDs: costumes.sorted(), propIDs: props.sorted()))
                case "素材":
                    guard let item = availableMaterials.first(where: { $0.id == materialID }), let url = item.fileLocation?.url,
                          let hash = await Task.detached(operation: { GlobalMaterialStore.verifiedContentFingerprint(item) }).value else { throw CharacterLibraryError.invalid("请选择内容未变且可读的素材") }
                    guard !next.assets.contains(where: { $0.subjectID == subjectID && $0.variantID == variantID && $0.materialID == materialID && $0.role == role && $0.stage == stage }) else { throw CharacterLibraryError.invalid("此造型、用途及阶段已关联该素材，请使用已有记录") }
                    let asset = ProjectAssetGraph.Asset(subjectID: subjectID, variantID: variantID, materialID: materialID, path: CharacterProjectModules.relative(url, root: root), sha256: hash, role: role, stage: stage, status: confirmed ? "已确认" : "候选", evidence: evidence, originalPrompt: prompt, reuseTemplate: reuse, platform: platform, model: model, referencePaths: references.components(separatedBy: .newlines).filter { !$0.isEmpty })
                    next.assets.append(asset)
                    next.events.append(.init(assetID: asset.id, action: confirmed ? "确认" : "登记候选", evidence: evidence))
                case "镜头":
                    let sourceURL = CharacterProjectModules.resolve(source, root: root)
                    let hash = source.isEmpty ? "" : try CharacterMarkdown.read(sourceURL).1
                    next.shots.append(.init(episode: episode, scene: scene, name: title, sourcePath: source, sourceFingerprint: hash))
                case "状态":
                    guard let i = next.assets.firstIndex(where: { $0.id == selectedAssetID }), !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CharacterLibraryError.invalid("请填写此次确认或停用依据") }
                    let asset = next.assets[i], root = root
                    if confirmed { try await Task.detached { try ProjectAssetGraph.verify(asset, root: root) }.value }
                    next.assets[i].status = confirmed ? "已确认" : "历史停用"
                    if confirmed { next.assets[i].evidence = evidence } else { next.assets[i].isDefault = false }
                    next.events.append(.init(assetID: selectedAssetID, action: next.assets[i].status, evidence: evidence))
                    if let person = characters.first(where: { $0.entry.characterID == asset.subjectID }), var profile = person.profile, let item = material(for: asset) {
                        for index in profile.assets.indices where profile.assets[index].materialID == item.id && profile.assets[index].role == asset.role && profile.assets[index].stage == asset.stage {
                            profile.assets[index].status = next.assets[i].status
                            if !confirmed { profile.assets[index].defaultUse = "" }
                        }
                        pendingCharacter = profile; pendingCharacterSource = person
                    }
                default: return
                }
                try next.validate(characterIDs: characterIDs)
                pending = next; pendingDescription = "将保存到项目资产标准记录：\(editor)。原始素材不移动、不覆盖；已有镜头使用版本保持不变。"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save(_ next: ProjectAssetGraph) {
        busy = true
        Task {
            defer { busy = false }
            var characterSaved = false
            do {
                try checkGraphCurrent()
                if let profile = pendingCharacter, let loaded = pendingCharacterSource {
                    if let asset = next.assets.first(where: { $0.id == selectedAssetID && $0.status == "已确认" }) { _ = try await verifiedMaterial(asset) }
                    guard await library.save(profile: profile, loaded: loaded) else { throw CharacterLibraryError.invalid(library.error ?? "人物默认用途保存失败") }
                    characterSaved = true
                }
                try ProjectAssetGraph.save(next, root: root, expected: expected, characterIDs: characterIDs)
                graph = next; expected = try CharacterMarkdown.read(ProjectAssetGraph.url(root: root)).1
                pending = nil; pendingCharacter = nil; pendingCharacterSource = nil; editor = ""; notice = "记录已保存，原素材和既有镜头引用未改变。"
            } catch { self.error = error.localizedDescription + (characterSaved ? "；人物默认用途已保存，项目资产记录未完成。候选保留，请刷新核对后补存；不要重复确认。" : "；编辑内容保留，请复制候选后刷新核对。") }
        }
    }
    private func previewDefault(_ asset: ProjectAssetGraph.Asset) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let item = try await verifiedMaterial(asset)
                var next = graph
                pendingCharacter = nil; pendingCharacterSource = nil
                if let person = characters.first(where: { $0.entry.characterID == asset.subjectID }), var profile = person.profile {
                    try profile.selectDefault(materialID: item.id, variant: variants.first { $0.id == asset.variantID }?.name ?? asset.variantID, role: asset.role, stage: asset.stage)
                    pendingCharacter = profile; pendingCharacterSource = person
                    // Character defaults have one authoritative owner: the original character MD.
                    for i in next.assets.indices where next.assets[i].subjectID == asset.subjectID { next.assets[i].isDefault = false }
                    next.events.append(.init(assetID: asset.id, action: "人物默认用途更新", evidence: "默认用途写回原人物 MD；已有镜头保持原版"))
                } else { try next.setDefault(asset.id) }
                pending = next; pendingDescription = "将此版本设为同主体、阶段和用途的默认；人物默认用途写回原人物 MD，其他主体保存在项目资产记录。已有镜头保持原版。"
                editor = "设置默认"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func material(for asset: ProjectAssetGraph.Asset) -> MaterialRecord? {
        let path = CharacterProjectModules.resolve(asset.path, root: root).resolvingSymlinksInPath().path
        return availableMaterials.first { $0.id == asset.materialID && $0.fileLocation?.url.resolvingSymlinksInPath().path == path }
            ?? availableMaterials.first { $0.fileLocation?.url.resolvingSymlinksInPath().path == path }
    }
    private func verifiedMaterial(_ asset: ProjectAssetGraph.Asset) async throws -> MaterialRecord {
        let root = root
        try await Task.detached { try ProjectAssetGraph.verify(asset, root: root) }.value
        guard let item = material(for: asset) else { throw CharacterLibraryError.invalid("文件未入素材库，请先通过现有导入入口建立原位索引") }
        return item
    }
    private func use(_ asset: ProjectAssetGraph.Asset) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try checkGraphCurrent()
                let item = try await verifiedMaterial(asset)
                guard let shot = graph.shots.first(where: { $0.id == selectedShotID }) else { throw CharacterLibraryError.invalid("请选择镜头") }
                if !shot.sourcePath.isEmpty, try CharacterMarkdown.read(CharacterProjectModules.resolve(shot.sourcePath, root: root)).1 != shot.sourceFingerprint { throw CharacterLibraryError.invalid("分镜原文变化，请刷新核对来源后重新登记镜头") }
                guard !materials.links.contains(where: { $0.projectID == project.id && $0.shotID == shot.id && $0.subjectID == asset.subjectID && $0.materialID == item.id }) else { throw CharacterLibraryError.invalid("此镜头已选用该主体的此版本") }
                let link = ProjectMaterialLink(id: UUID().uuidString, projectID: project.id, materialID: item.id, use: .working, episode: shot.episode, scene: shot.scene, shot: shot.name, selection: "选用", createdAt: .now, subjectID: asset.subjectID, variantID: asset.variantID, shotID: shot.id, boundFingerprint: asset.sha256, sourceDocument: shot.sourcePath.isEmpty ? nil : shot.sourcePath, sourceFingerprint: shot.sourceFingerprint.isEmpty ? nil : shot.sourceFingerprint, originalPrompt: asset.originalPrompt, reuseTemplate: asset.reuseTemplate)
                try await materials.commitUsage(link)
                notice = "已固定选用具体版本；后续默认版本变化不会替换此镜头。"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func replaceUsages() {
        guard let asset = selectedAsset else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            var completed = 0
            do {
                try checkGraphCurrent()
                let item = try await verifiedMaterial(asset)
                let selected = usages.filter { selectedUsages.contains($0.id) }
                for link in selected {
                    if let path = link.sourceDocument, let hash = link.sourceFingerprint,
                       try CharacterMarkdown.read(CharacterProjectModules.resolve(path, root: root)).1 != hash {
                        throw CharacterLibraryError.invalid("分镜来源变化，请核对后再更新引用：" + path)
                    }
                }
                for old in selected {
                    var link = old; link.materialID = item.id; link.boundFingerprint = asset.sha256
                    link.subjectID = asset.subjectID; link.variantID = asset.variantID; link.originalPrompt = asset.originalPrompt; link.reuseTemplate = asset.reuseTemplate
                    try await materials.commitUsage(link); completed += 1
                }
                editor = ""; selectedUsages = []; notice = "已更新 \(completed) 条明确选中的引用，其余镜头和历史保留。"
            } catch { self.error = "已完成 \(completed) 条，其余未改；" + error.localizedDescription }
        }
    }
    private func checkGraphCurrent() throws {
        guard try ProjectAssetGraph.read(root: root, projectID: project.id).1 == expected else { throw CharacterLibraryError.conflict }
    }
    private func handoff(_ asset: ProjectAssetGraph.Asset) -> String {
        """
        # 项目资产制作交接
        项目：\(project.name)（\(project.id)）
        项目根目录：\(root.path)
        主体 ID：\(asset.subjectID)；造型 ID：\(asset.variantID)
        具体文件：\(CharacterProjectModules.resolve(asset.path, root: root).path)
        SHA-256：\(asset.sha256)
        用途：\(asset.role)；阶段：\(asset.stage)；记录状态：\(asset.status)
        平台／模型：\(asset.platform) / \(asset.model)
        原始生成提示词：
        \(asset.originalPrompt.isEmpty ? "待补充" : asset.originalPrompt)
        标准化复用模板：
        \(asset.reuseTemplate.isEmpty ? "待补充" : asset.reuseTemplate)
        参考素材：\(asset.referencePaths.joined(separator: "\n"))
        先核对文件与来源。生成结果作为新版本登记；仅在用户明确确认后记录具体文件及依据。不得自动改写既有镜头或平台内容。
        """
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func indexConfirmedFiles() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            var urls: [URL] = [], failures: [String] = []
            do { try checkGraphCurrent() } catch { self.error = error.localizedDescription; return }
            let root = root
            for asset in graph.assets where currentStatus(asset) == "已确认" {
                do {
                    try await Task.detached { try ProjectAssetGraph.verify(asset, root: root) }.value
                    urls.append(CharacterProjectModules.resolve(asset.path, root: root))
                } catch { failures.append(asset.path + "：" + error.localizedDescription) }
            }
            if !urls.isEmpty { materials.importFiles(urls); await materials.waitForImportCompletion() }
            notice = "已将 \(urls.count) 个有效文件交给原位导入；原文件保留，已有素材复用。"
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    private func export() {
        let project = ProjectRecord(id: project.id, name: project.name, rootPath: project.rootPath, databasePath: "", isLegacy: false, lastOpenedAt: .now)
        materials.chooseDelivery(project: project)
    }
}
