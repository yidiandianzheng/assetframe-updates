import SwiftUI
import AppKit

/// Library-owned workflow. All network work starts from the explicit send confirmation.
struct MaterialTaggingWorkspace: View {
    @ObservedObject var store: GlobalMaterialStore
    let scopeIDs: Set<String>
    let selectedIDs: Set<String>
    let onClose: () -> Void
    @StateObject private var controller: MaterialTaggingController
    @State private var tab = "整理图片"
    @State private var scope = "所选图片"
    @State private var status = "待确认"
    @State private var search = ""
    @State private var page = 0
    @State private var picked: Set<String> = []
    @State private var issue: String?
    @State private var saving = false
    @State private var editingProposal: MaterialTaggingState.Proposal?
    @State private var editingTerm: MaterialTaggingState.Term?
    @State private var editingSource: MaterialTaggingState.Source?
    @State private var editingBinding: MaterialTaggingState.Binding?
    @State private var conflictProposal: MaterialTaggingState.Proposal?
    @State private var showsTaggingAPISettings = false
    @State private var apiConfigured = MaterialTaggingAPISettings.hasSavedConfiguration()
    @State private var pendingAI: TaggingSendPreview?
    @State private var bindingSearch = ""
    @State private var bindingMaterialID = ""
    @State private var bindingKind = "实际生成原文"
    @State private var termScope = "全部"
    @State private var recentResult = ""

    init(store: GlobalMaterialStore, scopeIDs: Set<String>, selectedIDs: Set<String>, onClose: @escaping () -> Void) {
        self.store = store; self.scopeIDs = scopeIDs; self.selectedIDs = selectedIDs; self.onClose = onClose
        _controller = StateObject(wrappedValue: MaterialTaggingController(store: store))
        _scope = State(initialValue: selectedIDs.isEmpty ? "当前文件夹／浏览范围" : "所选图片")
    }

    private var images: [MaterialRecord] { store.materials.filter { $0.deletedAt == nil && $0.kind == .image } }
    private var targetIDs: Set<String> {
        let allowed = scope == "所选图片" ? selectedIDs : scope == "当前文件夹／浏览范围" ? scopeIDs : Set(images.map(\.id))
        return Set(images.lazy.filter { allowed.contains($0.id) }.map(\.id))
    }
    private var proposals: [MaterialTaggingState.Proposal] {
        let names = search.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: store.materials.map { ($0.id, $0.name) })
        return store.tagging.proposals.filter { proposal in
            let matchesStatus: Bool
            switch status {
            case "全部": matchesStatus = true
            case "存在冲突": matchesStatus = proposal.hasConflict && proposal.status == "待确认"
            case "缺少资料": matchesStatus = proposal.missingDocuments && proposal.status == "待确认"
            case "处理失败": matchesStatus = proposal.status == "处理失败" || (proposal.status == "待确认" && !proposal.error.isEmpty)
            default: matchesStatus = proposal.status == status
            }
            return matchesStatus && (search.isEmpty || proposal.tags.joined(separator: " ").localizedCaseInsensitiveContains(search)
                || proposal.categories.displayText.localizedCaseInsensitiveContains(search)
                || (names[proposal.materialID] ?? "").localizedCaseInsensitiveContains(search))
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private var visibleProposals: [MaterialTaggingState.Proposal] { Array(proposals.dropFirst(page * 20).prefix(20)) }
    private var pickedProposals: [MaterialTaggingState.Proposal] { store.tagging.proposals.filter { picked.contains($0.id) && $0.status == "待确认" } }
    private var termOptions: [MaterialTaggingState.Term] {
        var terms = store.tagging.effectiveTerms
        let registered = Set(terms.filter { $0.dimension.isEmpty }.map(\.name))
        let unregistered = Set(store.materials.lazy.filter { $0.deletedAt == nil }.flatMap(\.tags)).subtracting(registered)
        terms.append(contentsOf: unregistered.map { .init(id: "existing-tag:" + MaterialTaggingState.digest(Data($0.utf8)), name: $0) })
        return terms.filter {
            (termScope == "全部" || (termScope == "常用" && $0.favorite) || (termScope == "自定义" && !$0.builtin) || (termScope == "已停用" && !$0.enabled)) &&
            (search.isEmpty || ([$0.name, $0.dimension, $0.scope] + $0.aliases).joined(separator: " ").localizedCaseInsensitiveContains(search))
        }.sorted { $0.favorite != $1.favorite ? $0.favorite : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("工作区", selection: $tab) {
                ForEach(["整理图片", "待确认", "标签管理", "资料来源"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            if controller.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(controller.progress).font(.callout)
                    Spacer()
                    Button("暂停") { controller.pause() }
                }
            } else if !controller.progress.isEmpty {
                Text(controller.progress).font(.caption).foregroundStyle(.secondary)
            }
            if let message = issue ?? controller.issue { Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !recentResult.isEmpty { Text(recentResult).font(.caption).foregroundStyle(.secondary) }
            Group {
                switch tab {
                case "待确认": reviewPanel
                case "标签管理": termsPanel
                case "资料来源": sourcesPanel
                default: organizePanel
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20).frame(minWidth: 880, idealWidth: 1040, minHeight: 620, idealHeight: 740)
        .frame(width: 1040, height: 740)
        .interactiveDismissDisabled(saving)
        .onDisappear { controller.pause() }
        .onChange(of: tab) { _, _ in search = ""; page = 0 }
        .onChange(of: status) { _, _ in page = 0; picked = [] }
        .onChange(of: search) { _, _ in page = 0 }
        .sheet(item: $editingProposal) { proposal in
            MaterialTaggingProposalEditor(proposal: proposal, material: store.materials.first { $0.id == proposal.materialID }, issue: issue, saving: saving) { edited in
                perform {
                    try await store.changeTagging("已保存候选修改") { state, records in
                        guard let index = state.proposals.firstIndex(where: { $0.id == edited.id }), state.proposals[index] == proposal else {
                            throw MaterialDatabase.error("候选已变化，请重新打开再编辑")
                        }
                        var draft = edited
                        if let record = records.first(where: { $0.id == draft.materialID }) {
                            draft.hasConflict = MaterialTaggingState.conflicts(draft, with: record)
                        }
                        state.proposals[index] = draft
                    }
                    editingProposal = nil
                }
            } onCancel: { editingProposal = nil }
        }
        .sheet(item: $editingTerm) { term in
            MaterialTaggingTermEditor(term: term, terms: store.tagging.effectiveTerms, issue: issue, saving: saving) { edited, mergeID in
                perform { try await store.saveTaggingTerm(edited, mergeInto: mergeID); editingTerm = nil }
            } onCancel: { editingTerm = nil }
        }
        .sheet(item: $editingSource) { source in
            MaterialTaggingSourceEditor(source: source, issue: issue, saving: saving) { edited in
                perform {
                    try await store.changeTagging("已保存资料来源设置") { state, _ in
                        guard let index = state.sources.firstIndex(where: { $0.id == source.id }), state.sources[index] == source else {
                            throw MaterialDatabase.error("资料来源已变化，请重新打开编辑")
                        }
                        state.sources[index] = edited
                    }
                    editingSource = nil
                }
            } onCancel: { editingSource = nil }
        }
        .sheet(item: $editingBinding) { binding in
            MaterialTaggingBindingEditor(binding: binding, issue: issue, saving: saving) { excerpt in
                saveExcerpt(excerpt, binding: binding)
            } onCancel: { editingBinding = nil }
        }
        .sheet(isPresented: $showsTaggingAPISettings, onDismiss: {
            apiConfigured = MaterialTaggingAPISettings.hasSavedConfiguration()
        }) { MaterialTaggingAPISettingsView(onClose: { showsTaggingAPISettings = false }) }
        .sheet(item: $pendingAI) { preview in sendConfirmation(preview) }
        .alert("确认替换或删除现有标签？", isPresented: conflictVisible) {
            Button("取消", role: .cancel) { conflictProposal = nil }
            Button("确认所列修改") {
                guard let proposal = conflictProposal else { return }
                conflictProposal = nil
                accept([proposal.id], allowConflicts: true)
            }
        } message: {
            Text(conflictDescription)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label("标签与分类", systemImage: "tag").font(.title2)
                Text("本机先整理 · AI 按需校正 · 由你确认").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(apiConfigured ? "已配置独立接口" : "尚未配置 AI 接口").font(.caption).foregroundStyle(.secondary)
            Button("AI 接口设置…", systemImage: "network") { showsTaggingAPISettings = true }.disabled(controller.busy || saving)
            Button("完成") { controller.pause(); onClose() }.keyboardShortcut(.cancelAction).disabled(saving)
        }
    }
    private var organizePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("整理范围") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("图片范围", selection: $scope) {
                        ForEach(["所选图片", "当前文件夹／浏览范围", "当前资源库"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.radioGroup)
                    Text("本次 \(targetIDs.count) 张图片。资料提取、看图与文字识别均在本机完成。").foregroundStyle(.secondary)
                    HStack {
                        Button("开始本机整理", systemImage: "sparkles") { controller.start(ids: targetIDs); tab = "待确认" }
                            .buttonStyle(.borderedProminent).disabled(targetIDs.isEmpty || controller.busy || saving || !store.canWrite)
                        Button("继续上次任务") { controller.resume() }.disabled(controller.busy || !store.canWrite || store.tagging.jobs.isEmpty)
                        Button("重试范围内失败图片") { controller.start(ids: targetIDs, retryFailed: true) }.disabled(controller.busy || targetIDs.isEmpty || !store.canWrite)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("整理依据") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("已绑定提示词、明确的图片引用和项目资料", systemImage: "doc.text")
                    Label("Apple Vision 画面建议、中英文文字和图片尺寸", systemImage: "desktopcomputer")
                    Label("有冲突、缺资料或不确定的图片会单独提示", systemImage: "questionmark.circle")
                    Text("本机结果正确时可直接确认。AI 校正需要在“待确认”中选中图片并明确点击发送。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("登记项目资料目录") { tab = "资料来源" }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let job = store.tagging.jobs.last {
                Text("上次任务：\(job.status) · 已处理 \(job.completed.count)/\(job.materialIDs.count) · 失败或部分识别 \(job.failed.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("状态", selection: $status) {
                    ForEach(["待确认", "存在冲突", "缺少资料", "处理失败", "已确认", "已忽略", "已过期", "全部"], id: \.self) { Text($0 == "处理失败" ? "失败／部分识别" : $0).tag($0) }
                }.frame(width: 190)
                TextField("搜索名称或候选标签", text: $search).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("选择本页待确认") { picked.formUnion(visibleProposals.filter { $0.status == "待确认" }.map(\.id)) }
                Button("清除选择") { picked = [] }.disabled(picked.isEmpty)
                Spacer()
                Button("撤销") { perform { _ = await store.undoEdit() } }.disabled(!store.canUndoEdit || saving || controller.busy)
                Button("重做") { perform { _ = await store.undoEdit(redo: true) } }.disabled(!store.canRedoEdit || saving || controller.busy)
                Text("已选 \(picked.count) 项").font(.caption)
                Menu("AI 校正所选") {
                    Button("文案与标签校正") { prepareAI("文本") }
                    Button("看图校正") { prepareAI("看图") }
                }.disabled(!apiConfigured || pickedProposals.isEmpty || pickedProposals.count > 20 || controller.busy || saving)
                Button("确认所选无冲突项") { accept(Set(pickedProposals.filter { !needsConflictConfirmation($0) }.map(\.id))) }
                    .disabled(pickedProposals.isEmpty || saving || controller.busy || !store.canWrite)
            }.font(.callout)
            Text("每批最多50项，整理历史保留最近20步；大范围确认请分批处理。").font(.caption).foregroundStyle(.secondary)
            if pickedProposals.count > 20 { Text("AI 每批最多 20 张，请减少选择；本机确认可分批保存。").font(.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if visibleProposals.isEmpty { ContentUnavailableView("暂无候选", systemImage: "tag", description: Text("先在“整理图片”中开始，或更换状态与搜索条件。")) }
                    ForEach(visibleProposals) { proposal in
                        MaterialTaggingProposalCard(proposal: proposal, material: store.materials.first { $0.id == proposal.materialID }, selected: picked.contains(proposal.id), disabled: saving || controller.busy,
                            select: { if picked.contains(proposal.id) { picked.remove(proposal.id) } else { picked.insert(proposal.id) } },
                            edit: { editingProposal = proposal },
                            ignore: { ignore(proposal) },
                            accept: { needsConflictConfirmation(proposal) ? (conflictProposal = proposal) : accept([proposal.id]) })
                    }
                }.padding(2)
            }
            pageControls(total: proposals.count, batchSize: 20)
        }
    }
    private var termsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("词条范围", selection: $termScope) { ForEach(["全部", "常用", "自定义", "已停用"], id: \.self) { Text($0).tag($0) } }.frame(width: 170)
                TextField("搜索词条、别名或项目", text: $search).textFieldStyle(.roundedBorder)
                Button("新增词条", systemImage: "plus") { editingTerm = .init(name: "") }.disabled(!store.canWrite || saving)
            }
            Text("常用是收藏属性；通用词和项目自定义词共用同一词表。停用后保留已标注结果。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(termOptions.dropFirst(page * 50).prefix(50))) { term in
                        HStack {
                            Button(term.favorite ? "取消常用" : "加入常用", systemImage: term.favorite ? "star.fill" : "star") {
                                var edited = term; edited.favorite.toggle(); saveTerm(edited)
                            }.labelStyle(.iconOnly).buttonStyle(.borderless).help(term.favorite ? "取消常用" : "加入常用")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.name).font(.headline)
                                Text([dimensionName(term.dimension), term.scope, term.builtin ? "内置" : "自定义", term.enabled ? "启用" : "已停用"].joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !term.aliases.isEmpty { Text("别名：" + term.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("编辑／合并") { editTerm(term) }
                            Button(term.enabled ? "停用" : "启用") { var edited = term; edited.enabled.toggle(); saveTerm(edited) }
                        }.padding(.vertical, 9).disabled(saving || !store.canWrite)
                        Divider()
                    }
                }
            }
            pageControls(total: termOptions.count, batchSize: 50)
        }.onChange(of: termScope) { _, _ in page = 0 }
    }
    private var sourcesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("本地项目资料目录").font(.headline)
                    Spacer()
                    Button("添加目录…", systemImage: "folder.badge.plus", action: addSource).disabled(saving || !store.canWrite)
                }
                Text("只读取文档与明确图文引用。名称相近、同目录等弱关系进入待关联提示。原项目文件保持原位。").font(.caption).foregroundStyle(.secondary)
                ForEach(store.tagging.sources) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.name)
                            Text("适用范围：" + (source.scope ?? "通用")).font(.caption).foregroundStyle(.secondary)
                            Text(source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("编辑名称／范围") { issue = nil; editingSource = source }
                        Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: source.path)) }
                        Button("取消登记") { perform { try await store.changeTagging("已取消资料目录登记") { state, _ in state.sources.removeAll { $0.id == source.id } } } }
                    }.disabled(saving)
                }
                Divider()
                Text("为图片明确绑定文档").font(.headline)
                TextField("搜索图片名称或 ID（至少 2 字）", text: $bindingSearch).textFieldStyle(.roundedBorder)
                    .onChange(of: bindingSearch) { _, _ in bindingMaterialID = "" }
                Picker("图片", selection: $bindingMaterialID) {
                    Text("请选择图片").tag("")
                    ForEach(bindingCandidates) { Text($0.name).tag($0.id) }
                }
                Picker("资料性质", selection: $bindingKind) { ForEach(["实际生成原文", "复用模板", "一般参考资料"], id: \.self) { Text($0).tag($0) } }
                Button("选择文档并绑定…", action: bindDocument).disabled(bindingMaterialID.isEmpty || saving || !store.canWrite)
                Text("实际生成原文应是这张图片真实使用的原文；多图文档会继续检查可定位片段。绑定资料不会把提示词期望自动当作图片事实。").font(.caption).foregroundStyle(.secondary)
                if !bindingMaterialID.isEmpty {
                    ForEach(store.tagging.bindings.filter { $0.materialID == bindingMaterialID }) { binding in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(binding.kind)
                                Text(binding.documentPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let excerpt = binding.excerpt, !excerpt.isEmpty {
                                    Text("已绑定对应片段 · \(excerpt.count) 字").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("打开文档") { NSWorkspace.shared.open(URL(fileURLWithPath: binding.documentPath)) }
                            Button("编辑对应片段") { issue = nil; editingBinding = binding }
                            Button("解除绑定") { perform { try await store.changeTagging("已解除资料绑定") { state, _ in state.bindings.removeAll { $0.id == binding.id } } } }
                        }.disabled(saving)
                    }
                }
            }.padding(2)
        }
    }
    private var bindingCandidates: [MaterialRecord] {
        guard bindingSearch.count >= 2 else { return images.filter { selectedIDs.contains($0.id) }.prefix(40).map { $0 } }
        return Array(images.lazy.filter { $0.name.localizedCaseInsensitiveContains(bindingSearch) || $0.id.localizedCaseInsensitiveContains(bindingSearch) }.prefix(40))
    }
    private func pageControls(total: Int, batchSize: Int) -> some View {
        HStack {
            Text("共 \(total) 项 · 每页 \(batchSize) 项").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
            Text("\(page + 1) / \(max(1, (total + batchSize - 1) / batchSize))").font(.caption).monospacedDigit()
            Button("下一页") { page += 1 }.disabled((page + 1) * batchSize >= total)
        }
    }
    private func dimensionName(_ id: String) -> String { id.isEmpty ? "自由标签" : ClassificationVocabulary.dimension(id)?.name ?? id }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }
        saving = true; issue = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await work() } catch { issue = error.localizedDescription }
        }
    }
    private func saveTerm(_ term: MaterialTaggingState.Term) { perform { try await store.saveTaggingTerm(term) } }
    private func editTerm(_ term: MaterialTaggingState.Term) {
        issue = nil
        if store.tagging.effectiveTerms.contains(where: { $0.id == term.id }) { editingTerm = term }
        else { perform { try await store.saveTaggingTerm(term); editingTerm = term } }
    }
    private func ignore(_ proposal: MaterialTaggingState.Proposal) {
        perform {
            try await store.changeTagging("已忽略候选") { state, _ in
                guard let index = state.proposals.firstIndex(where: { $0.id == proposal.id }), state.proposals[index].status == "待确认" else { throw MaterialDatabase.error("候选已变化") }
                state.proposals[index].status = "已忽略"; state.proposals[index].decidedAt = .now
            }
            picked.remove(proposal.id)
        }
    }
    private func accept(_ ids: Set<String>, allowConflicts: Bool = false) {
        guard !ids.isEmpty else { issue = "所选图片均有冲突，请逐项查看并确认修改。"; return }
        perform {
            try await store.acceptTagging(ids: ids, allowConflicts: allowConflicts)
            picked.subtract(ids); recentResult = "已保存确认结果；可从“资产”菜单撤销／重做素材整理。"
        }
    }
    private var conflictVisible: Binding<Bool> { Binding(get: { conflictProposal != nil }, set: { if !$0 { conflictProposal = nil } }) }
    private func needsConflictConfirmation(_ proposal: MaterialTaggingState.Proposal) -> Bool {
        guard let record = store.materials.first(where: { $0.id == proposal.materialID }) else { return true }
        return proposal.hasConflict || MaterialTaggingState.conflicts(proposal, with: record)
    }
    private var conflictDescription: String {
        guard let proposal = conflictProposal else { return "" }
        let record = store.materials.first { $0.id == proposal.materialID }
        return "图片：\(record?.name ?? proposal.materialID)\n现有分类：\(record?.classificationDisplayText ?? "")\n建议新增分类：\(proposal.categories.displayText)\n建议移除分类：\(proposal.removeCategories?.displayText ?? "无")\n建议移除标签：\(proposal.removeTags.joined(separator: "、"))\n人工确认的内容只有本次明确确认后才会改变。"
    }
    private func addSource() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try await store.changeTagging("已登记资料目录") { state, _ in
                guard !state.sources.contains(where: { $0.path == url.path }) else { return }
                state.sources.append(.init(name: url.lastPathComponent, path: url.path))
            }
            editingSource = store.tagging.sources.first { $0.path == url.path }
        }
    }
    private func bindDocument() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = bindingMaterialID, kind = bindingKind
        perform {
            try await store.changeTagging("已绑定图片资料") { state, _ in
                state.bindings.removeAll { $0.materialID == id && $0.documentPath == url.path }
                state.bindings.append(.init(materialID: id, documentPath: url.path, kind: kind))
            }
            editingBinding = store.tagging.bindings.first { $0.materialID == id && $0.documentPath == url.path }
        }
    }
    private func saveExcerpt(_ excerpt: String?, binding: MaterialTaggingState.Binding) {
        perform {
            // Read before joining the write queue, then check that exact document version at commit.
            let document = try await Task.detached(priority: .utility) {
                try CharacterMarkdown.read(URL(fileURLWithPath: binding.documentPath))
            }.value
            if let excerpt {
                guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, excerpt.count <= 12000,
                      let first = document.0.range(of: excerpt),
                      document.0.range(of: excerpt, range: document.0.index(after: first.lowerBound)..<document.0.endIndex) == nil else {
                    throw MaterialDatabase.error("片段必须不超过12000字，且在当前文档原文中恰好出现一次；请复制含必要上下文的完整片段")
                }
            }
            try await store.changeTagging("已保存图片对应原文片段，可撤销", undoable: true) { state, _ in
                guard let index = state.bindings.firstIndex(where: { $0.id == binding.id }), state.bindings[index] == binding else {
                    throw MaterialDatabase.error("资料绑定已变化，请重新打开编辑")
                }
                guard try MaterialTaggingState.fileDigest(binding.documentPath) == document.1 else {
                    throw MaterialDatabase.error("文档原文已变化，请重新复制对应片段")
                }
                state.bindings[index].excerpt = excerpt
            }
            editingBinding = nil
        }
    }
    private func prepareAI(_ mode: String) {
        let chosen = pickedProposals
        guard (1...20).contains(chosen.count) else { issue = "每批请选择 1–20 张待确认图片"; return }
        do {
            let configuration = try MaterialTaggingAIClient.configuration(mode: mode)
            let endpoint = configuration.baseURL, model = configuration.model
            pendingAI = .init(mode: mode, ids: Set(chosen.map(\.materialID)), endpoint: endpoint, model: model,
                              names: chosen.map { proposal in store.materials.first { $0.id == proposal.materialID }?.name ?? proposal.materialID },
                              evidenceCount: chosen.reduce(0) { $0 + $1.evidence.filter { !$0.excerpt.isEmpty }.count })
        } catch { issue = error.localizedDescription }
    }
    private func sendConfirmation(_ preview: TaggingSendPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发送所选内容进行 AI 校正").font(.title2)
            LabeledContent("接收服务", value: preview.endpoint)
            LabeledContent("模型", value: preview.model)
            LabeledContent("图片数量", value: "\(preview.ids.count) 张")
            Text(preview.mode == "看图" ? "发送范围：所选图片的压缩分析副本、关联文案片段和现有标签。" : "发送范围：所选图片的关联文案片段和现有标签；不发送图片。")
            Text("候选来源片段 \(preview.evidenceCount) 条；只发送这批关联内容，不发送整个资料目录。").font(.caption).foregroundStyle(.secondary)
            Text(preview.names.joined(separator: "、")).lineLimit(5).font(.caption).foregroundStyle(.secondary)
            Text("可能产生 API 费用。返回结果仍需你确认；失败或取消不会自动重试付费请求。").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { pendingAI = nil }.keyboardShortcut(.cancelAction)
                Button("发送并校正") { sendAI(preview) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620)
    }
    private func sendAI(_ preview: TaggingSendPreview) {
        pendingAI = nil
        do {
            let configuration = try MaterialTaggingAIClient.configuration(mode: preview.mode)
            let endpoint = configuration.baseURL, model = configuration.model
            guard endpoint == preview.endpoint, model == preview.model else { issue = "接口或模型已变化，请重新查看发送范围"; return }
            controller.correct(ids: preview.ids, mode: preview.mode)
        } catch { issue = error.localizedDescription }
    }
}

private struct TaggingSendPreview: Identifiable {
    let id = UUID()
    let mode: String
    let ids: Set<String>
    let endpoint: String
    let model: String
    let names: [String]
    let evidenceCount: Int
}
