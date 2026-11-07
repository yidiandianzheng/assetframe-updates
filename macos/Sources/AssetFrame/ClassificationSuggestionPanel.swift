import SwiftUI

/// 「待确认」分类箱：规则引擎与本机视觉／相似图的结果都先落在这里，采纳后才写进正式分类。
///
/// 每条建议固定显示五项——分类名、涉及张数、最多 4 张样图、依据、把握程度（高／中／低，用文字不用只靠颜色）；
/// 每条给四个动作：采纳、改名后采纳、忽略、拆分或合并，另有整批采纳。所有动作走同一条撤销栈。
struct ClassificationSuggestionPanel: View {
    @ObservedObject var store: GlobalMaterialStore
    /// 本机整理正在跑时禁用写入，避免和 AI 候选抢同一个提交队列。
    let busy: Bool

    @State private var filter = "待确认"
    @State private var search = ""
    @State private var page = 0
    @State private var issue: String?
    @State private var saving = false
    @State private var renameTarget: MaterialTaggingState.Suggestion?
    @State private var renameText = ""
    @State private var splitTarget: MaterialTaggingState.Suggestion?
    @State private var splitName = ""
    @State private var splitPicked: Set<String> = []

    private static let pageSize = 12

    private func matchesSearch(_ suggestion: MaterialTaggingState.Suggestion, names: [String: String]) -> Bool {
        guard !search.isEmpty else { return true }
        if suggestion.name.localizedCaseInsensitiveContains(search) { return true }
        if dimensionName(suggestion.dimension).localizedCaseInsensitiveContains(search) { return true }
        if suggestion.detail.localizedCaseInsensitiveContains(search) { return true }
        return suggestion.materialIDs.contains { (names[$0] ?? "").localizedCaseInsensitiveContains(search) }
    }

    private var suggestions: [MaterialTaggingState.Suggestion] {
        let names = Dictionary(store.materials.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let matching = (store.tagging.suggestions ?? []).filter { suggestion in
            let statusOK: Bool
            switch filter {
            case "全部": statusOK = true
            case "已处理": statusOK = suggestion.status != "待确认"
            default: statusOK = suggestion.status == filter
            }
            return statusOK && matchesSearch(suggestion, names: names)
        }
        return matching.sorted { lhs, rhs in
            let leftPending = lhs.status == "待确认", rightPending = rhs.status == "待确认"
            if leftPending != rightPending { return leftPending }
            if lhs.itemCount != rhs.itemCount { return lhs.itemCount > rhs.itemCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    private var visible: [MaterialTaggingState.Suggestion] { Array(suggestions.dropFirst(page * Self.pageSize).prefix(Self.pageSize)) }
    private var pendingCount: Int { store.tagging.pendingSuggestions.count }
    private var pendingImages: Int { Set(store.tagging.pendingSuggestions.flatMap(\.materialIDs)).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            summary
            if let issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if store.isIndexingSuggestions {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("已索引 \(store.suggestionIndexed) / \(store.suggestionIndexTotal)").font(.callout).monospacedDigit()
                    Spacer()
                    Button("停止") { store.suggestionIndexTask?.cancel() }
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 480, maximum: 900), spacing: 12)], alignment: .leading, spacing: 12) {
                    if visible.isEmpty {
                        ContentUnavailableView("箱里没有建议", systemImage: "tray",
                            description: Text(store.tagging.suggestions == nil
                                ? "点「扫描命名规则」或「扫描相似图」，结果会先进这里；采纳前不会改动正式分类。"
                                : "换一下状态或搜索条件；已处理的历史条目在「已处理」里查看。"))
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(visible) { suggestion in card(suggestion) }
                }.padding(2)
            }
            HStack {
                Text("共 \(suggestions.count) 组 · 每页 \(Self.pageSize) 组").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
                Text("\(page + 1) / \(max(1, (suggestions.count + Self.pageSize - 1) / Self.pageSize))").font(.caption).monospacedDigit()
                Button("下一页") { page += 1 }.disabled((page + 1) * Self.pageSize >= suggestions.count)
            }
        }
        .onChange(of: filter) { _, _ in page = 0 }
        .onChange(of: search) { _, _ in page = 0 }
        .sheet(item: $renameTarget) { suggestion in renameSheet(suggestion) }
        .sheet(item: $splitTarget) { suggestion in splitSheet(suggestion) }
    }

    private var toolbar: some View {
        HStack {
            Picker("状态", selection: $filter) {
                ForEach(["待确认", "已处理", "全部"], id: \.self) { Text($0).tag($0) }
            }.frame(width: 170)
            TextField("搜索分类名、依据或图片名", text: $search).textFieldStyle(.roundedBorder)
            Button("扫描命名规则") { perform { await store.indexClassificationRules() } }
                .disabled(busy || saving || store.isIndexingSuggestions || !store.canWrite)
                .help("按目录名与文件名给出建议，不读画面")
            Button("扫描相似图", systemImage: "sparkles") { perform { await store.refreshClassificationSuggestions() } }
                .disabled(busy || saving || store.isIndexingSuggestions || !store.canWrite)
                .help("本机 Vision 读取特征，按相似图与画面内容给建议；逐张显示进度")
            Button("整批采纳") { perform { try await store.adoptAllClassificationSuggestions() } }
                .disabled(pendingCount == 0 || busy || saving || !store.canWrite)
            Button("撤销") { perform { _ = await store.undoEdit() } }.disabled(!store.canUndoEdit || saving || busy)
            Button("重做") { perform { _ = await store.undoEdit(redo: true) } }.disabled(!store.canRedoEdit || saving || busy)
        }.font(.callout)
    }

    private var summary: some View {
        Text(pendingCount > 0
            ? "\(pendingCount) 组建议待确认，涉及 \(pendingImages) 张图片；采纳才写入正式分类，每次写入都能撤销。"
            : "没有待确认的分类建议。新导入的图片会在导入结束后自动按命名规则进箱。")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - 单条建议

    @ViewBuilder
    private func card(_ suggestion: MaterialTaggingState.Suggestion) -> some View {
        let samples = suggestion.sampleIDs.compactMap { id in store.materials.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(dimensionName(suggestion.dimension))：\(suggestion.name)").font(.headline)
                if suggestion.isNewTerm {
                    Text("新词·待确认").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("把握：\(suggestion.confidence)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("\(suggestion.itemCount) 张 · 来源：\(suggestion.engine) · 依据：\(suggestion.basis.isEmpty ? "—" : suggestion.basis.joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary)
            if !samples.isEmpty {
                HStack(spacing: 6) {
                    ForEach(samples) { material in
                        MaterialThumbnailView(material: material, showFormatBadge: false, previewMaximumDimension: 220)
                            .frame(width: 74, height: 74).clipped()
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    }
                }
            }
            if !suggestion.detail.isEmpty {
                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            if suggestion.status == "待确认" {
                HStack {
                    Button("采纳") { perform { try await store.adoptClassificationSuggestion(suggestion.id) } }
                    Button("改名后采纳") {
                        renameText = suggestion.name
                        renameTarget = suggestion
                    }
                    Button("忽略") { perform { try await store.ignoreClassificationSuggestion(suggestion.id) } }
                    Menu("拆分／合并") {
                        Button("拆出一部分…") {
                            splitPicked = []
                            splitName = ""
                            splitTarget = suggestion
                        }
                        ForEach(mergeTargets(suggestion)) { target in
                            Button("并到「\(target.name)」") {
                                perform { try await store.mergeClassificationSuggestion(suggestion.id, into: target.id) }
                            }
                        }
                        if mergeTargets(suggestion).isEmpty {
                            Text("同维度暂无其他待确认建议").disabled(true)
                        }
                    }
                    Spacer()
                }.controlSize(.small)
            } else {
                Text(suggestion.status + (suggestion.mergedInto != nil ? "（并入了另一条建议）" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .disabled(saving || busy || !store.canWrite)
    }

    private func mergeTargets(_ suggestion: MaterialTaggingState.Suggestion) -> [MaterialTaggingState.Suggestion] {
        store.tagging.pendingSuggestions.filter { $0.id != suggestion.id && $0.dimension == suggestion.dimension }
    }

    // MARK: - 改名与拆分

    private func renameSheet(_ suggestion: MaterialTaggingState.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("改名后采纳「\(suggestion.name)」").font(.headline)
            Text("涉及 \(suggestion.itemCount) 张；改后的名字会连同这一组一起记住，下次重跑沿用新名字。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("新的分类名", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Button("取消") { renameTarget = nil }.keyboardShortcut(.cancelAction)
                Button("改名后采纳") {
                    let name = renameText
                    renameTarget = nil
                    perform { try await store.adoptClassificationSuggestion(suggestion.id, renamedTo: name) }
                }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }.padding(16).frame(width: 420, height: 170)
    }

    private func splitSheet(_ suggestion: MaterialTaggingState.Suggestion) -> some View {
        let rows = suggestion.materialIDs.compactMap { id in store.materials.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 12) {
            Text("从「\(suggestion.name)」拆出一组").font(.headline)
            Text("勾选要移走的图片（本组共 \(rows.count) 张，最多列出 200 张）；剩下的仍留在原建议里。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("拆出后的分类名", text: $splitName).textFieldStyle(.roundedBorder).frame(width: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.prefix(200))) { material in
                        Toggle(isOn: Binding(
                            get: { splitPicked.contains(material.id) },
                            set: { on in if on { splitPicked.insert(material.id) } else { splitPicked.remove(material.id) } }
                        )) {
                            HStack {
                                Text(material.name).lineLimit(1)
                                Text(material.sourcePath ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }.frame(height: 220)
            HStack {
                Text("已选 \(splitPicked.count) 张").font(.caption)
                Spacer()
                Button("取消") { splitTarget = nil }.keyboardShortcut(.cancelAction)
                Button("拆出新建议") {
                    let ids = Array(splitPicked), name = splitName
                    splitTarget = nil
                    perform { try await store.splitClassificationSuggestion(suggestion.id, name: name, materialIDs: ids) }
                }.disabled(splitPicked.isEmpty || splitPicked.count >= suggestion.itemCount
                    || splitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(16).frame(width: 520, height: 420)
    }

    private func dimensionName(_ id: String) -> String { ClassificationVocabulary.dimension(id)?.name ?? id }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }
        saving = true
        issue = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await work() } catch { issue = error.localizedDescription }
        }
    }
}
