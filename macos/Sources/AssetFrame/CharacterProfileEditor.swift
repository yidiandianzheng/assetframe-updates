import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CharacterProfileEditor: View {
    @ObservedObject var library: CharacterLibraryStore
    @ObservedObject var materials: GlobalMaterialStore
    let loaded: CharacterLibraryStore.Loaded
    let onClose: () -> Void
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var draft: CharacterProfile
    @State private var tab = "人物介绍"
    @State private var previewText: String?
    @State private var previewApproved = false
    @State private var discardConfirmation = false
    @State private var materialSearch = ""
    @State private var selectedMaterial = ""
    @State private var sourcePath = ""
    @State private var aiSources: [CharacterExtractionClient.Source] = []
    @State private var suggestions: [CharacterExtractionClient.Suggestion] = []
    @State private var accepted: Set<String> = []
    @State private var showSettings = false
    @State private var aiRunning = false
    @State private var aiTask: Task<Void, Never>?
    @State private var error: String?
    @State private var saving = false
    private var dirty: Bool { draft != loaded.profile }

    init(library: CharacterLibraryStore, materials: GlobalMaterialStore, loaded: CharacterLibraryStore.Loaded, onClose: @escaping () -> Void) {
        self.library = library; self.materials = materials; self.loaded = loaded; self.onClose = onClose
        _draft = State(initialValue: loaded.profile ?? CharacterProfile(projectID: loaded.entry.projectID, characterID: loaded.entry.characterID))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(previewText == nil ? "整理人物 · \(draft.name)" : "核对 MD 写回差异").font(.title2.bold())
                Spacer()
                Text("原文件与历史段落保留").font(.caption).foregroundStyle(.secondary)
            }
            Text(loaded.entry.sourcePath).font(.caption).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = library.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let previewText {
                HSplitView {
                    sourcePreview("写回前", loaded.text)
                    sourcePreview("写回后（只替换标准档案区块）", previewText)
                }
                Text("保存前会核对源文件是否变化，并备份原字节。新旧文件均可在下方复制。").font(.caption)
                HStack {
                    Button("返回编辑") { self.previewText = nil; previewApproved = false }
                    Button("复制写回后内容") { copy(previewText) }
                    Spacer()
                    Button(saving ? "保存中…" : "确认写回 MD") { Task { _ = await save() } }
                        .disabled(saving || !materials.canWrite || !library.canEdit)
                }
            } else {
                Picker("编辑栏目", selection: $tab) {
                    ForEach(["人物介绍", "说话特点", "剧情记录", "人物资产", "生成模板", "资料与 AI"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let group = CharacterProfile.groups.first(where: { $0.0 == tab }) {
                            ForEach(group.1, id: \.self) { fieldEditor($0) }
                        } else if tab == "人物资产" { assetEditor }
                        else if tab == "剧情记录" { storyEditor }
                        else { aiEditor }
                    }.padding(.vertical, 8)
                }
                HStack {
                    Button("取消") { if dirty { discardConfirmation = true } else { close() } }
                    Button("复制草稿") {
                        do { copy(try CharacterMarkdown.render(draft, replacing: loaded.text)) }
                        catch { self.error = error.localizedDescription }
                    }
                    Spacer()
                    Button("预览写回…") {
                        do { previewText = try CharacterMarkdown.render(draft, replacing: loaded.text); previewApproved = true; error = nil; updateGuard() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!dirty || aiRunning || saving)
                }
            }
        }.padding(20).frame(minWidth: 820, idealWidth: 960, minHeight: 610, idealHeight: 760)
        .interactiveDismissDisabled()
        .onAppear { updateGuard() }
        .onChange(of: draft) { _, _ in previewApproved = false; updateGuard() }
        .onDisappear { aiTask?.cancel(); editGuard.dirty = false; editGuard.save = nil; editGuard.discard = nil }
        .confirmationDialog("放弃本次未保存的整理？", isPresented: $discardConfirmation) {
            Button("放弃草稿", role: .destructive) { close() }
            Button("继续编辑", role: .cancel) { }
        }
        .sheet(isPresented: $showSettings) {
            DeepSeekSettingsView(task: .characterOrganization, startsAfterSave: false,
                usageDescription: "只在点击发送分析后，上传本页主动选择的 MD 文字。结果先作为候选展示。",
                onSave: { _ in showSettings = false }, onCancel: { showSettings = false })
        }
    }
    private func sourcePreview(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 350, maxHeight: .infinity)
    }
    private func fieldEditor(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key).font(.headline)
                Spacer()
                Picker("确认状态", selection: Binding(get: { draft.fields[key]?.review ?? .pending }, set: { draft.fields[key, default: .init()].review = $0 })) {
                    ForEach(CharacterProfile.Review.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 160)
            }
            TextEditor(text: Binding(get: { draft.fields[key]?.text ?? "" }, set: { draft.fields[key, default: .init()].text = $0 }))
                .font(.body).frame(height: key.contains("提示词") ? 145 : 70).border(Color.secondary.opacity(0.25)).accessibilityLabel(key)
            TextField("依据／原文位置（可选）", text: Binding(get: { draft.fields[key]?.evidence ?? "" }, set: { draft.fields[key, default: .init()].evidence = $0 })).textFieldStyle(.roundedBorder)
        }
    }
    private var assetEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("关联固定素材 ID；确认、历史停用和默认用途分别记录。评分不会自动确认资产。").font(.caption)
            TextField("查找库内素材", text: $materialSearch).textFieldStyle(.roundedBorder)
            Picker("素材", selection: $selectedMaterial) {
                Text("选择素材").tag("")
                ForEach(materials.materials.filter { $0.deletedAt == nil && (materialSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(materialSearch)) }.prefix(100)) { material in
                    Text(material.name + " · " + material.id.suffix(6)).tag(material.id)
                }
            }
            HStack {
                Text("显示前 100 项，可输入名称缩小范围。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关联为候选资产") { draft.assets.append(.init(materialID: selectedMaterial)); selectedMaterial = "" }.disabled(selectedMaterial.isEmpty)
            }
            ForEach($draft.assets) { $asset in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(materials.materials.first { $0.id == asset.materialID }?.name ?? "素材记录缺失").font(.headline)
                            Spacer(); Button("解除此关联") { draft.assets.removeAll { $0.id == asset.id } }
                        }
                        TextField("造型版本", text: $asset.variant)
                        HStack {
                            Picker("角色用途", selection: $asset.role) { ForEach(CharacterProfile.Asset.roles, id: \.self) { Text($0).tag($0) } }
                            Picker("资产状态", selection: $asset.status) { ForEach(CharacterProfile.Asset.statuses, id: \.self) { Text($0).tag($0) } }
                        }
                        TextField("适用阶段／集数", text: $asset.stage)
                        TextField("当前默认用途（如开局脸部参考；留空为非默认）", text: $asset.defaultUse)
                    }.textFieldStyle(.roundedBorder).padding(4)
                }
            }
        }
    }
    private var storyEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("添加剧情记录") { draft.stories.append(.init()) }
            ForEach($draft.stories) { $story in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("集数／剧情阶段", text: $story.episode)
                            Picker("状态", selection: $story.state) { ForEach(["当前正文", "后续规划", "历史停用", "待确认"], id: \.self) { Text($0).tag($0) } }
                            Button("移除") { draft.stories.removeAll { $0.id == story.id } }
                        }
                        TextEditor(text: $story.summary).frame(height: 75).border(Color.secondary.opacity(0.25)).accessibilityLabel("剧情摘要")
                        TextField("原文路径（可带 # 标题锚点）", text: $story.source)
                        Button("选择剧情 MD…") { if let url = chooseOneMD() { story.source = url.path } }
                    }.textFieldStyle(.roundedBorder).padding(4)
                }
            }
        }
    }
    private var aiEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("关联资料").font(.headline)
            ForEach(draft.sources, id: \.self) { path in
                HStack { Text(path).font(.caption).textSelection(.enabled); Spacer(); Button("移除关联") { draft.sources.removeAll { $0 == path } } }
            }
            Button("关联介绍／模板 MD…") {
                if let url = chooseOneMD(), !draft.sources.contains(url.path) { draft.sources.append(url.path) }
            }
            Divider()
            Text("DeepSeek 辅助整理").font(.headline)
            Text("关联资料不自动上传。请单独选择本次要发送的 MD，核对内容后再分析。AI 只生成候选，资产状态与人物 ID 不会被修改。").font(.caption)
            HStack {
                Button("配置接口…") { showSettings = true }
                Button("选择本次分析 MD…") { chooseAISources() }.disabled(aiRunning)
                if aiRunning { ProgressView().controlSize(.small); Button("取消分析") { aiTask?.cancel() } }
            }
            ForEach(aiSources, id: \.path) { source in
                DisclosureGroup(source.path) { Text(source.text).font(.caption).textSelection(.enabled) }
            }
            if !aiSources.isEmpty {
                Text("将发送 \(aiSources.count) 个文件，共 \(aiSources.reduce(0) { $0 + $1.text.utf8.count }) 字节；可能产生 API 费用。").font(.caption)
                Button("发送所选文字并分析") { analyze() }.disabled(aiRunning)
            }
            ForEach(suggestions) { suggestion in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("采纳候选：\(suggestion.field)", isOn: Binding(get: { accepted.contains(suggestion.id) }, set: { if $0 { accepted.insert(suggestion.id) } else { accepted.remove(suggestion.id) } }))
                        Text("现有：\(draft.fields[suggestion.field]?.text ?? "待补充")").foregroundStyle(.secondary)
                        Text("建议：\(suggestion.value)").textSelection(.enabled)
                        Text("来源：\(suggestion.source)\n原文：\(suggestion.evidence)").font(.caption).textSelection(.enabled)
                        if !suggestion.conflict.isEmpty { Text("冲突／待核对：\(suggestion.conflict)").foregroundStyle(.orange) }
                        if let old = draft.fields[suggestion.field], !old.text.isEmpty, old.text != suggestion.value {
                            Text("将替换现有栏目（原状态：\(old.review.rawValue)），采纳后为候选；请先核对差异。").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !suggestions.isEmpty {
                Button("将勾选项加入草稿") {
                    for item in suggestions where accepted.contains(item.id) {
                        draft.fields[item.field] = .init(text: item.value, review: .candidate, evidence: item.source + "\n" + item.evidence + (item.conflict.isEmpty ? "" : "\n待核对：" + item.conflict))
                    }
                    suggestions.removeAll { accepted.contains($0.id) }; accepted = []
                }.disabled(accepted.isEmpty)
            }
        }
    }
    private func chooseOneMD() -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func chooseAISources() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            let sources = try panel.urls.map { CharacterExtractionClient.Source(path: $0.path, text: try CharacterMarkdown.read($0).0) }
            guard sources.reduce(0, { $0 + $1.text.utf8.count }) <= 160_000 else { throw CharacterLibraryError.invalid("所选文件超过 160 KB，请分批整理") }
            aiSources = sources; suggestions = []; accepted = []; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func analyze() {
        guard let config = DeepSeekAPISettings.storedConfiguration(for: .characterOrganization) else { error = "请先配置 DeepSeek 接口"; return }
        let sources = aiSources, name = draft.name
        aiRunning = true; error = nil; suggestions = []; accepted = []
        aiTask = Task {
            defer { aiRunning = false }
            do {
                let result = try await CharacterExtractionClient.analyze(sources: sources, characterName: name, configuration: config)
                try Task.checkCancellation(); suggestions = result
                if result.isEmpty { error = "没有提取到有原文依据的栏目，请手动整理或换一组资料。" }
            } catch is CancellationError { error = "分析已取消，草稿保留" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func updateGuard() {
        editGuard.dirty = dirty
        editGuard.save = {
            guard previewApproved else { error = "请取消离开，在人物编辑窗先预览写回。草稿仍保留。"; return false }
            return await save()
        }
        editGuard.discard = { close() }
    }
    private func save() async -> Bool {
        guard !saving, materials.canWrite, previewApproved else { return false }
        saving = true; defer { saving = false }
        if await library.save(profile: draft, loaded: loaded) { close(); return true }
        return false
    }
    private func close() { aiTask?.cancel(); editGuard.dirty = false; editGuard.save = nil; editGuard.discard = nil; onClose() }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
