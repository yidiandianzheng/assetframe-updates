import SwiftUI

/// Scoped to a library/store instance. Dismissal cancels work; applying tags uses the existing undoable store.
struct MaterialIntelligenceView: View {
    @ObservedObject var store: GlobalMaterialStore
    let scopeIDs: Set<String>
    let selectedIDs: Set<String>
    let onClose: () -> Void
    @State private var tab = 0
    @State private var query = ""
    @State private var intent: MaterialIntent?
    @State private var results: [MaterialRecord] = []
    @State private var proposals: [MaterialTagProposal] = []
    @State private var picked: [String: Set<String>] = [:]
    @State private var groups: [MaterialSimilarityScan.Group] = []
    @State private var pair: [String] = []
    @State private var visualDifference: OpenAICompatibleVisionClient.Comparison?
    @State private var comparisonSources: [MaterialAnalysisSource] = []
    @State private var issue: String?
    @State private var progress = ""
    @State private var busy = false
    @State private var saving = false
    @State private var job: Task<Void, Never>?
    @State private var sending: Sending?
    @State private var textConfiguration: DeepSeekConfiguration?
    @State private var visionConfiguration: VisionAPIConfiguration?
    @State private var pendingRecords: [MaterialRecord] = []
    @State private var pendingQuery = ""
    @State private var confirmation = false
    @State private var versionConfirmation = false
    @State private var showTagging = false
    private enum Sending { case query, tags, comparison }

    private var scope: [MaterialRecord] { store.materials.filter { scopeIDs.contains($0.id) && $0.deletedAt == nil } }
    private var targets: [MaterialRecord] { scope.filter { selectedIDs.contains($0.id) && $0.kind == .image } }
    private var pairRecords: [MaterialRecord] { pair.compactMap { id in scope.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("智能整理", systemImage: "sparkles").font(.title2)
                Spacer()
                Text("当前浏览范围 \(scope.count) 项 · 已选图片 \(targets.count) 张").font(.caption).foregroundStyle(.secondary)
                Button("完成", action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
            }
            Picker("功能", selection: $tab) {
                Text("一句话找素材").tag(0)
                Text(AppProduct.current == .assets ? "标签与分类" : "自动标签测试").tag(1)
                Text("相似素材与版本差异").tag(2)
            }.pickerStyle(.segmented).disabled(busy)
            if busy {
                HStack { ProgressView().controlSize(.small); Text(progress); Spacer(); Button("停止") { job?.cancel(); busy = false; progress = "已停止" }.disabled(saving) }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            switch tab {
            case 1:
                if AppProduct.current == .assets {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("自动标签已整合到“标签与分类”", systemImage: "tag").font(.headline)
                        Text("本机提取文案与识图后，按需 AI 校正，并保存候选供你批量确认。").foregroundStyle(.secondary)
                        Button("打开标签与分类…", systemImage: "tag") { showTagging = true }.buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else { tagsPanel }
            case 2: similarityPanel
            default: searchPanel
            }
        }
        .padding(20).frame(width: 960, height: 660)
        .interactiveDismissDisabled(saving)
        .onDisappear { job?.cancel() }
        .alert("发送所选内容进行 AI 分析？", isPresented: $confirmation) {
            Button("取消", role: .cancel) { sending = nil }
            Button("发送并分析") { send() }
        } message: { Text(uploadDescription) }
        .alert("将 A 和 B 关联到同一版本组？", isPresented: $versionConfirmation) {
            Button("取消", role: .cancel) { }
            Button("关联版本") { linkPair() }
        } message: { Text("此操作将合并两项已有的版本组。原文件、审核状态和镜头固定选用保持不变；可通过撤销素材整理恢复。") }
        .onChange(of: pair) { _, _ in visualDifference = nil; comparisonSources = [] }
        .sheet(isPresented: $showTagging) {
            MaterialTaggingWorkspace(store: store, scopeIDs: scopeIDs, selectedIDs: selectedIDs) { showTagging = false }
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("例如：找横屏的院子图片。AI 将句子拆成检索条件，再在本库名称、标签、备注和提示词中查找。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("描述你要找的素材…", text: $query).textFieldStyle(.roundedBorder).onSubmit { searchLocal() }
                Button("本机关键词查找", action: searchLocal).disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("AI 理解后查找") { prepare(.query) }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.count > 1000)
            }
            if let intent { Text("检索条件：\(intent.summary)").font(.callout).textSelection(.enabled) }
            Text("尚未标注的画面细节可能找不到，可先测试自动标签。本机关键词模式不理解复杂否定；联网模式仅发送这句查询。").font(.caption).foregroundStyle(.secondary)
            if intent != nil && results.isEmpty { ContentUnavailableView("未找到匹配素材", systemImage: "magnifyingglass", description: Text("调整条件，或为相关图片确认标签后重试。")) }
            List(results.prefix(200)) { record in
                HStack {
                    MaterialThumbnailView(material: record).frame(width: 72, height: 54)
                    VStack(alignment: .leading) { Text(record.name); Text(record.tags.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button("预览") { preview(record.id) }
                }
            }
            Text("\(results.count) 项匹配\(results.count > 200 ? "，显示前200项，请缩小条件" : "")").font(.caption)
        }
    }

    private var tagsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先在画册选中 1–20 张图片，再打开此页。候选标签默认不勾选，采纳只追加标签，可撤销；不会修改名称、审核状态或原文件。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("本机识别测试") { analyzeLocal() }.disabled(busy || targets.isEmpty || targets.count > 20)
                Button("视觉模型标签测试") { prepare(.tags) }.disabled(busy || targets.isEmpty || targets.count > 20)
                Spacer()
                Button("采纳勾选标签") { applyTags() }.disabled(busy || !store.canWrite || !picked.values.contains(where: { !$0.isEmpty }))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(proposals) { proposal in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(scope.first { $0.id == proposal.id }?.name ?? proposal.id).font(.headline); Spacer(); Button("预览") { preview(proposal.id) } }
                            Text("\(proposal.engine)：\(proposal.evidence)").font(.caption).foregroundStyle(.secondary)
                            if proposal.tags.isEmpty { Text("没有足够可靠的标签，请手工补充。").font(.caption) }
                            ForEach(proposal.tags, id: \.self) { tag in
                                Toggle(tag, isOn: Binding(get: { picked[proposal.id, default: []].contains(tag) }, set: { yes in
                                    if yes { picked[proposal.id, default: []].insert(tag) } else { picked[proposal.id, default: []].remove(tag) }
                                }))
                            }
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var similarityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("查找相似分组") { scan() }.disabled(busy || scope.isEmpty)
                Button("比较已选两张") { pair = targets.prefix(2).map(\.id) }.disabled(busy || targets.count != 2)
                Spacer()
                Text("本机指纹＋视觉特征；结构1000张 / AI特征200张上限").font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(group.materialIDs.count) 项相似候选").font(.headline)
                        Text(group.reason).font(.caption).foregroundStyle(.secondary)
                        ForEach(group.materialIDs, id: \.self) { id in
                            if let record = scope.first(where: { $0.id == id }) {
                                HStack {
                                    Toggle(record.name, isOn: Binding(get: { pair.contains(id) }, set: { yes in
                                        if yes && pair.count < 2 { pair.append(id) } else if !yes { pair.removeAll { $0 == id } }
                                    })).lineLimit(1)
                                    Button("预览") { preview(id) }
                                }
                            }
                        }
                    }
                }.frame(minWidth: 260)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("选两项比较（A → B，不代表先后顺序）").font(.headline); Spacer(); Button("清空") { pair = [] }.disabled(busy) }
                        ForEach(Array(pairRecords.enumerated()), id: \.element.id) { index, record in
                            HStack { MaterialThumbnailView(material: record).frame(width: 90, height: 70); Text("\(index == 0 ? "A" : "B")：\(record.name)"); Spacer(); Button("预览") { preview(record.id) } }
                        }
                        if pairRecords.count == 2 {
                            Text("已记录字段差异").font(.headline)
                            ForEach(Array(MaterialVersionDifference.describe(pairRecords[0], pairRecords[1]).enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                            HStack {
                                Button("AI 说明画面差异") { prepare(.comparison) }.disabled(busy || !pairRecords.allSatisfy { $0.kind == .image })
                                Button("关联为同组版本") { versionConfirmation = true }.disabled(busy || !store.canWrite || pairRecords[0].kind != pairRecords[1].kind)
                            }
                            Text("分析副本最长边1280像素，小字和细节仍需原图核对。").font(.caption).foregroundStyle(.secondary)
                            if let visualDifference {
                                Text("AI 画面差异（待核对）").font(.headline)
                                ForEach(Array(visualDifference.differences.enumerated()), id: \.offset) { _, line in Text("• " + line).textSelection(.enabled) }
                                ForEach(Array(visualDifference.uncertainties.enumerated()), id: \.offset) { _, line in Text("待核对：" + line).foregroundStyle(.secondary) }
                            }
                        }
                    }.padding(8)
                }.frame(minWidth: 400)
            }
        }
    }

    private func preview(_ id: String) {
        if let record = store.materials.first(where: { $0.id == id && $0.deletedAt == nil }) { MaterialQuickLookController.shared.show(record) }
    }
    private func searchLocal() {
        let parsed = MaterialIntent.local(query)
        search(using: parsed)
        issue = "本机分词检索；复杂语义可使用 AI 理解后查找。"
    }
    private func search(using intent: MaterialIntent) {
        let records = scope
        start("正在检索本库…") {
            let worker = Task.detached(priority: .userInitiated) { intent.search(records) }
            let found = await worker.value
            guard !Task.isCancelled else { return }
            self.intent = intent; self.results = found
        }
    }
    private func start(_ message: String, work: @escaping @MainActor () async throws -> Void) {
        job?.cancel(); busy = true; issue = nil; progress = message
        job = Task { @MainActor in
            do { try await work() } catch { if !Task.isCancelled { issue = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
    private func analyzeLocal() {
        let records = targets
        proposals = []; picked = [:]
        start("正在本机识别…") {
            for (index, record) in records.enumerated() {
                try Task.checkCancellation()
                progress = "本机识别 \(index + 1)/\(records.count)"
                do {
                    let worker = Task.detached(priority: .utility) { try MaterialLocalTags.analyze(record) }
                    let proposal = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation(); proposals.append(proposal)
                } catch { if Task.isCancelled { throw error }; issue = "\(record.name)：\(error.localizedDescription)；其他图片继续。" }
            }
        }
    }
    private func applyTags() {
        let selected = proposals.filter { !picked[$0.id, default: []].isEmpty }
        guard selected.allSatisfy({ proposal in
            guard let current = store.materials.first(where: { $0.id == proposal.id }) else { return false }
            return (try? MaterialAnalysisSource.capture(current)) == proposal.source
        }) else { issue = "素材已移动、变更或移入回收站，请重新识别后再采纳。"; return }
        let tags = picked
        store.batchUpdate(Set(selected.map(\.id))) { record in record.tags = Array(Set(record.tags).union(tags[record.id, default: []])).sorted() }
        saving = true
        start("保存标签…") {
            defer { saving = false }
            try await store.saveNow().get()
            proposals.removeAll { tags[$0.id]?.isEmpty == false }; picked = [:]
            issue = "已追加标签；可用“资产 → 撤销素材整理”恢复。"
        }
    }
    private func scan() {
        let records = scope
        groups = []; pair = []
        start("正在查找相似素材…") {
            let worker = Task.detached(priority: .utility) { MaterialVisualSimilarity.scan(records) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            groups = result.groups
            issue = "找到\(groups.count)组；AI特征分析\(result.featureImages)张，\(result.skippedImages)张未完成\(result.truncated ? "；已达到扫描或结果上限，请缩小范围" : "")。分组是候选，不自动判断版本。"
        }
    }
    private var uploadDescription: String {
        if sending == .query {
            return "接收地址：\(textConfiguration?.baseURL ?? "")\n模型：\(textConfiguration?.model ?? "")\n只发送查询：\(pendingQuery)\n不发送素材、路径或库清单；可能产生 API 费用。"
        }
        return "接收地址：\(visionConfiguration?.baseURL ?? "")\n模型：\(visionConfiguration?.model ?? "")\n发送\(pendingRecords.count)张图片的压缩分析副本\(sending == .tags ? "及文件名" : "")：\n\(pendingRecords.map(\.name).joined(separator: "、"))\n原图不改动；可能产生 API 费用。"
    }
    private func prepare(_ action: Sending) {
        do {
            sending = action
            if action == .query { textConfiguration = try DeepSeekAPISettings.checkedConfiguration(); pendingQuery = query }
            else {
                guard let config = VisionAPISettings.storedConfiguration() else { issue = "请先在设置中配置支持图片输入的视觉 API。"; return }
                visionConfiguration = config; pendingRecords = action == .tags ? targets : pairRecords
                guard action == .tags ? (1...20).contains(pendingRecords.count) : pendingRecords.count == 2 else { return }
                comparisonSources = try pendingRecords.map { try MaterialAnalysisSource.capture($0) }
            }
            confirmation = true
        } catch { issue = error.localizedDescription }
    }
    private func send() {
        let action = sending, records = pendingRecords, sources = comparisonSources
        if action == .query, let config = textConfiguration {
            let query = pendingQuery, records = scope
            start("AI 正在理解查询…") {
                let parsed = try await MaterialIntent.interpret(query, configuration: config)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { parsed.search(records) }
                let found = await worker.value
                try Task.checkCancellation(); intent = parsed; results = found
            }
        } else if let config = visionConfiguration {
            start(action == .tags ? "正在生成标签候选…" : "正在比较画面…") {
                guard try records.map({ try MaterialAnalysisSource.capture($0) }) == sources else { throw CocoaError(.fileReadUnknown) }
                let client = OpenAICompatibleVisionClient()
                if action == .tags {
                    proposals = []; picked = [:]
                    for (index, record) in records.enumerated() {
                        try Task.checkCancellation(); progress = "视觉标签 \(index + 1)/\(records.count)"
                        let suggestion = try await client.analyze(input: VisionAnalysisInput(itemID: record.id, imagePath: sources[index].path, filename: record.originalFilename, currentType: record.assetType ?? .unclassified, localVisionLabels: []), configuration: config)
                        try Task.checkCancellation()
                        guard try MaterialAnalysisSource.capture(record) == sources[index] else { throw CocoaError(.fileReadUnknown) }
                        proposals.append(.init(source: sources[index], tags: suggestion.normalizedTags, evidence: suggestion.summary, engine: config.model))
                    }
                } else {
                    let response = try await client.compare(paths: sources.map(\.path), configuration: config)
                    try Task.checkCancellation()
                    guard try records.map({ try MaterialAnalysisSource.capture($0) }) == sources, pair == records.map(\.id) else { throw CocoaError(.fileReadUnknown) }
                    visualDifference = response
                }
            }
        }
        sending = nil
    }
    private func linkPair() {
        let records = pairRecords
        guard records.count == 2, store.canWrite else { return }
        store.setVersion(records[1].id, relativeTo: records[0].id)
        saving = true
        start("保存版本关联…") { defer { saving = false }; try await store.saveNow().get(); issue = "已关联版本组，镜头固定选用保持不变。" }
    }
}
