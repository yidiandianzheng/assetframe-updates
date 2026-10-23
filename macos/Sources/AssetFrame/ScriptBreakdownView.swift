import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ScriptChecklistFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待匹配"
    case linked = "已绑定"
    case missing = "待补图"
    case excluded = "不需要"
    var id: String { rawValue }
}

struct ScriptBreakdownView: View {
    @ObservedObject var store: AssetStore
    @State private var selectedExtractionID: String?
    @State private var search = ""
    @State private var typeFilter: AssetType?
    @State private var checklistFilter: ScriptChecklistFilter = .all
    @State private var pendingScriptURL: URL?
    @State private var pendingScriptAllowsDuplicate = false
    @State private var pendingScriptConsent: ScriptUploadConsent?
    @State private var isPreparingScript = false
    @State private var scriptPreparationError: String?
    @State private var showAISettings = false
    @State private var deleteRecordID: String?
    @State private var pickerCandidate: ScriptAssetCandidate?
    @State private var stackRoute: AssetStackSheetRoute?
    @State private var dropTargetCandidateID: String?

    private let allowedTypes: [AssetType] = [.person, .scene, .prop]

    private var extraction: ScriptExtractionRecord? {
        if let selectedExtractionID,
           let record = store.scriptExtractions.first(where: { $0.id == selectedExtractionID }) { return record }
        return store.scriptExtractions.first
    }

    private var filteredCandidates: [ScriptAssetCandidate] {
        guard let extraction else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return extraction.candidates.filter { candidate in
            let matchesSearch = query.isEmpty || "\(candidate.name) \(candidate.effectiveFormName) \(candidate.appearances.joined(separator: " ")) \(candidate.evidence) \(candidate.note)"
                .localizedStandardContains(query)
            let matchesType = typeFilter == nil || candidate.type == typeFilter
            let matchesState: Bool = switch checklistFilter {
            case .all: true
            case .pending: candidate.isRequiredForProduction && candidate.effectiveLinkState == .pending
            case .linked: candidate.isRequiredForProduction && candidate.effectiveLinkState == .linked
            case .missing: candidate.isRequiredForProduction && candidate.effectiveLinkState == .missing
            case .excluded: !candidate.isRequiredForProduction
            }
            return matchesSearch && matchesType && matchesState
        }
    }

    private var summary: (required: Int, linked: Int, missing: Int, pending: Int) {
        let candidates = extraction?.candidates ?? []
        let required = candidates.filter(\.isRequiredForProduction)
        return (
            required.count,
            required.filter { $0.effectiveLinkState == .linked }.count,
            required.filter { $0.effectiveLinkState == .missing }.count,
            required.filter { $0.effectiveLinkState == .pending }.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: selectLatestRecord)
        .onChange(of: store.scriptExtractions.map(\.id)) { _, _ in selectLatestRecord() }
        .sheet(isPresented: $showAISettings) {
            DeepSeekSettingsView(
                task: .scriptExtraction,
                startsAfterSave: pendingScriptURL != nil,
                usageDescription: "只上传你主动选择的剧本或分镜文字，不上传图片。AI只生成候选清单，正式资产与主图必须由你人工绑定。",
                onSave: { configuration in
                    showAISettings = false
                    if let url = pendingScriptURL {
                        store.startScriptExtraction(
                            from: url,
                            configuration: configuration,
                            allowDuplicate: pendingScriptAllowsDuplicate
                        )
                    }
                    pendingScriptURL = nil
                    pendingScriptAllowsDuplicate = false
                },
                onCancel: {
                    showAISettings = false
                    pendingScriptURL = nil
                    pendingScriptAllowsDuplicate = false
                }
            )
        }
        .sheet(item: $pendingScriptConsent) { consent in
            ScriptUploadConfirmationView(
                consent: consent,
                onConfirm: { confirmScriptUpload(consent) },
                onCancel: { pendingScriptConsent = nil }
            )
        }
        .sheet(item: $pickerCandidate) { candidate in
            if let extraction {
                ScriptVariantPickerSheet(
                    store: store,
                    extractionID: extraction.id,
                    candidateID: candidate.id
                )
            }
        }
        .sheet(item: $stackRoute) { route in
            AssetStackDetailView(store: store, stackID: route.id)
        }
        .alert("删除这份剧本资产清单？", isPresented: Binding(
            get: { deleteRecordID != nil },
            set: { if !$0 { deleteRecordID = nil } }
        )) {
            Button("取消", role: .cancel) { deleteRecordID = nil }
            Button("删除清单", role: .destructive) {
                if let id = deleteRecordID { store.removeScriptExtraction(id) }
                deleteRecordID = nil
            }
        } message: {
            Text("只删除这份剧本需求清单；不会删除正式资产、形态、主图或用户原文件。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("剧本查缺").font(.title2.bold())
                    Text("读取 MD / 分镜脚本 → 只提取人物、场景、道具 → 人工绑定正式主图 → 导出飞书表格")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("AI 接口", systemImage: "gearshape") {
                    pendingScriptURL = nil
                    pendingScriptAllowsDuplicate = false
                    showAISettings = true
                }
                if let extraction {
                    Button("导出确认表", systemImage: "tablecells") {
                        store.exportScriptAssetChecklist(extractionID: extraction.id)
                    }
                }
                Button(isPreparingScript ? "正在读取…" : "读取剧本 / MD", systemImage: "doc.badge.plus", action: chooseScript)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExtracting || isPreparingScript)
            }

            if let scriptPreparationError {
                Label(scriptPreparationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if extraction != nil {
                HStack(spacing: 18) {
                    checklistMetric("需要", value: summary.required, color: .primary)
                    checklistMetric("已绑定", value: summary.linked, color: .green)
                    checklistMetric("待补图", value: summary.missing, color: .orange)
                    checklistMetric("待匹配", value: summary.pending, color: .red)
                    Spacer()
                    Text(summary.pending == 0 ? "所有选用项已完成判断，可导出" : "还有 \(summary.pending) 项需要绑定正式资产或标记待补图")
                        .font(.caption)
                        .foregroundStyle(summary.pending == 0 ? Color.secondary : Color.orange)
                }
            }

            if let progress = store.scriptExtractionProgress {
                HStack(spacing: 10) {
                    if [.reading, .analyzing].contains(progress.phase) {
                        ProgressView(value: progress.fraction).frame(width: 150)
                    } else {
                        Image(systemName: progress.phase == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(progress.phase == .completed ? .green : .orange)
                    }
                    Text(progress.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(isExtracting ? "取消" : "关闭") {
                        isExtracting ? store.cancelScriptExtraction() : store.dismissScriptExtractionProgress()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(18)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            if !store.scriptExtractions.isEmpty {
                Picker("资产清单", selection: Binding(
                    get: { extraction?.id },
                    set: { selectedExtractionID = $0 }
                )) {
                    ForEach(store.scriptExtractions) { record in
                        Text("\(record.sourceName) · \(record.candidates.count) 项").tag(record.id as String?)
                    }
                }
                .frame(width: 260)
            }
            TextField("搜索名称、形态、场次或原文依据…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Picker("类型", selection: $typeFilter) {
                Text("全部类型").tag(nil as AssetType?)
                ForEach(allowedTypes) { Text($0.rawValue).tag($0 as AssetType?) }
            }
            .frame(width: 120)
            Picker("确认状态", selection: $checklistFilter) {
                ForEach(ScriptChecklistFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 120)
            Spacer()
            if let extraction {
                Button("全部设为需要") {
                    extraction.candidates.forEach {
                        store.setScriptCandidateRequired(extractionID: extraction.id, candidateID: $0.id, required: true)
                    }
                }
                Button(role: .destructive) { deleteRecordID = extraction.id } label: {
                    Label("删除清单", systemImage: "trash")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if store.scriptExtractions.isEmpty {
            ContentUnavailableView(
                "还没有剧本资产清单",
                systemImage: "doc.text.magnifyingglass",
                description: Text("读取 MD、TXT、RTF、PDF 或分镜脚本，生成可人工选用和绑定正式图片的资产表")
            )
        } else if filteredCandidates.isEmpty {
            ContentUnavailableView("当前筛选没有记录", systemImage: "line.3.horizontal.decrease.circle")
        } else if let extraction {
            VStack(spacing: 0) {
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCandidates) { candidate in
                            candidateRow(candidate, extractionID: extraction.id)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("使用").frame(width: 38)
            Text("类型").frame(width: 86, alignment: .leading)
            Text("剧本资产名称（自动带形态）/ 原文依据").frame(maxWidth: .infinity, alignment: .leading)
            Text("稳定形态").frame(width: 140, alignment: .leading)
            Text("出现位置").frame(width: 150, alignment: .leading)
            Text("等级").frame(width: 62, alignment: .leading)
            Text("候选叠图 / 正式主图").frame(width: 320, alignment: .leading)
            Text("状态").frame(width: 72, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func candidateRow(_ candidate: ScriptAssetCandidate, extractionID: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: requiredBinding(extractionID, candidate))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 38)
                .help("勾选表示本项目确实需要这个资产")

            Picker("", selection: typeBinding(extractionID, candidate)) {
                ForEach(allowedTypes) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 86)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 0) {
                    TextField("资产主体名称", text: candidateBinding(extractionID, candidate.id, \.name, fallback: candidate.name))
                        .font(.callout.bold())
                        .textFieldStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(candidate.formQualifiedName)
                    if candidate.effectiveFormName != "基础" {
                        Text("（\(candidate.effectiveFormName)）")
                            .font(.callout.bold())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(candidate.evidence.isEmpty ? "暂无原文依据" : candidate.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                TextField("备注或待确认项", text: candidateBinding(extractionID, candidate.id, \.note, fallback: candidate.note))
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                TextField("基础 / 战损 / 夜景", text: formBinding(extractionID, candidate))
                    .textFieldStyle(.roundedBorder)
                Button("新增同名形态", systemImage: "plus") {
                    store.addScriptCandidateForm(extractionID: extractionID, candidateID: candidate.id)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("为同一资产新增基础、换装、战损或变身等稳定形态")
            }
            .frame(width: 140)

            TextField("如：第1集第2场", text: appearancesBinding(extractionID, candidate))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Picker("", selection: candidateBinding(extractionID, candidate.id, \.reuse, fallback: candidate.reuse)) {
                ForEach(ReuseGrade.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 62)

            linkedAssetCell(candidate)
                .frame(width: 320, alignment: .leading)

            checklistStatus(candidate)
                .frame(width: 72, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(dropTargetCandidateID == candidate.id ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay {
            if dropTargetCandidateID == candidate.id {
                RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .opacity(candidate.isRequiredForProduction ? 1 : 0.48)
        .onDrop(
            of: [AssetDragPasteboard.identifier, UTType.fileURL.identifier],
            delegate: ScriptCandidateDropDelegate(
                store: store,
                extractionID: extractionID,
                candidateID: candidate.id,
                activeCandidateID: $dropTargetCandidateID
            )
        )
        .contextMenu {
            if candidate.isRequiredForProduction {
                Button("选择正式资产…") { pickerCandidate = candidate }
                if let variantID = candidate.draftVariantID, store.stack(withID: variantID) != nil {
                    Button("打开候选裁定台") { stackRoute = AssetStackSheetRoute(id: variantID) }
                }
                Button("新增同名形态") {
                    store.addScriptCandidateForm(extractionID: extractionID, candidateID: candidate.id)
                }
                Button("标记待补图") {
                    store.markScriptCandidateMissing(extractionID: extractionID, candidateID: candidate.id)
                }
                if candidate.effectiveLinkState != .pending {
                    Button("清除匹配结果") {
                        store.clearScriptCandidateLink(extractionID: extractionID, candidateID: candidate.id)
                    }
                }
                Divider()
                Button("本项目不需要") {
                    store.setScriptCandidateRequired(extractionID: extractionID, candidateID: candidate.id, required: false)
                }
            } else {
                Button("恢复为需要") {
                    store.setScriptCandidateRequired(extractionID: extractionID, candidateID: candidate.id, required: true)
                }
            }
        }
    }

    @ViewBuilder private func linkedAssetCell(_ candidate: ScriptAssetCandidate) -> some View {
        if let variantID = candidate.linkedVariantID,
           let variant = store.stack(withID: variantID),
           let entity = store.entity(for: variant),
           let mainID = variant.mainAssetID,
           let main = store.asset(withID: mainID) {
            HStack(spacing: 9) {
                AssetPreviewThumbnail(asset: main, size: CGSize(width: 68, height: 48), contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entity.name) · \(variant.effectiveVariantName)")
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text(variant.effectiveCallCode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("更换") { pickerCandidate = candidate }
                    .controlSize(.small)
            }
        } else if let variantID = candidate.draftVariantID,
                  let variant = store.stack(withID: variantID) {
            Button {
                stackRoute = AssetStackSheetRoute(id: variant.id)
            } label: {
                HStack(spacing: 9) {
                    stackedPreview(variant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(variant.count) 张候选 · \(variant.effectiveVariantName)")
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text("第一张仅为默认封面 · 点击人工裁定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                Image(systemName: candidate.effectiveLinkState == .missing ? "photo.badge.exclamationmark" : "square.stack.3d.up")
                    .foregroundStyle(candidate.effectiveLinkState == .missing ? .orange : .secondary)
                Text(candidate.effectiveLinkState == .missing ? "已明确待补图" : "拖入图片叠成候选组")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("选择…") { pickerCandidate = candidate }
                    .controlSize(.small)
            }
        }
    }

    private func stackedPreview(_ variant: AssetVariantRecord) -> some View {
        let cover = store.asset(withID: variant.coverAssetID)
        let backs = variant.memberAssetIDs.filter { $0 != variant.coverAssetID }.prefix(2).compactMap(store.asset(withID:))
        return ZStack(alignment: .leading) {
            ForEach(Array(backs.enumerated()), id: \.element.id) { offset, asset in
                AssetThumbnail(asset: asset, size: CGSize(width: 52, height: 42), contentMode: .fit)
                    .frame(width: 52, height: 42)
                    .offset(x: CGFloat(offset + 1) * 9)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2) }
            }
            if let cover {
                AssetThumbnail(asset: cover, size: CGSize(width: 52, height: 42), contentMode: .fit)
                    .frame(width: 52, height: 42)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2) }
            }
        }
        .frame(width: 72, height: 44, alignment: .leading)
    }

    private func checklistStatus(_ candidate: ScriptAssetCandidate) -> some View {
        let text = candidate.isRequiredForProduction ? candidate.effectiveLinkState.rawValue : "不需要"
        let color: Color = if !candidate.isRequiredForProduction {
            .secondary
        } else {
            switch candidate.effectiveLinkState {
            case .pending: .red
            case .linked: .green
            case .missing: .orange
            }
        }
        return Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
    }

    private func checklistMetric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").bold()
        }
        .font(.caption)
    }

    private var isExtracting: Bool {
        guard let phase = store.scriptExtractionProgress?.phase else { return false }
        return phase == .reading || phase == .analyzing
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.title = "读取剧本或分镜脚本"
        panel.prompt = "读取并生成资产清单"
        panel.allowedContentTypes = ScriptDocumentReader.supportedTypes
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareScriptConsent(for: url)
    }

    private func prepareScriptConsent(for url: URL) {
        isPreparingScript = true
        scriptPreparationError = nil
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    let text = try ScriptDocumentReader.read(url: url)
                    return (
                        text.count,
                        ScriptAssetExtractionClient.estimatedChunkCount(for: text),
                        ScriptDocumentReader.fingerprint(text)
                    )
                }.value
                pendingScriptConsent = ScriptUploadConsent(
                    url: url,
                    characterCount: preview.0,
                    chunkCount: preview.1,
                    fingerprint: preview.2,
                    isDuplicate: store.hasScriptExtraction(textFingerprint: preview.2)
                )
            } catch {
                scriptPreparationError = error.localizedDescription
            }
            isPreparingScript = false
        }
    }

    private func confirmScriptUpload(_ consent: ScriptUploadConsent) {
        pendingScriptConsent = nil
        pendingScriptURL = consent.url
        pendingScriptAllowsDuplicate = consent.isDuplicate
        guard let configuration = DeepSeekAPISettings.storedConfiguration(for: .scriptExtraction) else {
            showAISettings = true
            return
        }
        pendingScriptURL = nil
        pendingScriptAllowsDuplicate = false
        store.startScriptExtraction(
            from: consent.url,
            configuration: configuration,
            allowDuplicate: consent.isDuplicate
        )
    }

    private func selectLatestRecord() {
        if let selectedExtractionID, store.scriptExtractions.contains(where: { $0.id == selectedExtractionID }) { return }
        selectedExtractionID = store.scriptExtractions.first?.id
    }

    private func candidateBinding<Value>(
        _ extractionID: String,
        _ candidateID: String,
        _ keyPath: WritableKeyPath<ScriptAssetCandidate, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                store.scriptExtractions.first(where: { $0.id == extractionID })?
                    .candidates.first(where: { $0.id == candidateID })?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                store.updateScriptCandidate(extractionID: extractionID, candidateID: candidateID) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func requiredBinding(_ extractionID: String, _ candidate: ScriptAssetCandidate) -> Binding<Bool> {
        Binding(
            get: {
                store.scriptExtractions.first(where: { $0.id == extractionID })?
                    .candidates.first(where: { $0.id == candidate.id })?.isRequiredForProduction ?? candidate.isRequiredForProduction
            },
            set: { required in
                store.setScriptCandidateRequired(extractionID: extractionID, candidateID: candidate.id, required: required)
            }
        )
    }

    private func typeBinding(_ extractionID: String, _ candidate: ScriptAssetCandidate) -> Binding<AssetType> {
        Binding(
            get: {
                store.scriptExtractions.first(where: { $0.id == extractionID })?
                    .candidates.first(where: { $0.id == candidate.id })?.type ?? candidate.type
            },
            set: { type in
                store.updateScriptCandidate(extractionID: extractionID, candidateID: candidate.id) {
                    $0.type = type
                    $0.draftVariantID = nil
                    $0.linkedVariantID = nil
                    $0.linkState = .pending
                    $0.status = .pending
                }
            }
        )
    }

    private func formBinding(_ extractionID: String, _ candidate: ScriptAssetCandidate) -> Binding<String> {
        Binding(
            get: {
                store.scriptExtractions.first(where: { $0.id == extractionID })?
                    .candidates.first(where: { $0.id == candidate.id })?.effectiveFormName ?? candidate.effectiveFormName
            },
            set: { value in
                store.updateScriptCandidate(extractionID: extractionID, candidateID: candidate.id) { $0.formName = value }
            }
        )
    }

    private func appearancesBinding(_ extractionID: String, _ candidate: ScriptAssetCandidate) -> Binding<String> {
        Binding(
            get: {
                store.scriptExtractions.first(where: { $0.id == extractionID })?
                    .candidates.first(where: { $0.id == candidate.id })?.appearances.joined(separator: "、") ?? candidate.appearances.joined(separator: "、")
            },
            set: { text in
                store.updateScriptCandidate(extractionID: extractionID, candidateID: candidate.id) {
                    $0.appearances = text.split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" })
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            }
        )
    }
}

private struct ScriptCandidateDropDelegate: DropDelegate {
    let store: AssetStore
    let extractionID: String
    let candidateID: String
    @Binding var activeCandidateID: String?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [AssetDragPasteboard.identifier, UTType.fileURL.identifier])
    }

    func dropEntered(info: DropInfo) { activeCandidateID = candidateID }
    func dropExited(info: DropInfo) {
        if activeCandidateID == candidateID { activeCandidateID = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [AssetDragPasteboard.identifier, UTType.fileURL.identifier])
        guard !providers.isEmpty else { return false }
        activeCandidateID = nil
        ScriptAssetDropLoader.load(providers) { sources in
            Task { @MainActor in
                store.attachDroppedSources(sources, extractionID: extractionID, candidateID: candidateID)
            }
        }
        return true
    }
}

private enum ScriptAssetDropLoader {
    static func load(
        _ providers: [NSItemProvider],
        completion: @escaping @Sendable ([ScriptAssetDropSource]) -> Void
    ) {
        let accumulator = ScriptAssetDropAccumulator(count: providers.count, completion: completion)
        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(AssetDragPasteboard.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: AssetDragPasteboard.identifier) { data, _ in
                    let source = data.flatMap { try? JSONDecoder().decode(AssetDragPayload.self, from: $0) }
                        .map { ScriptAssetDropSource.libraryAsset(projectID: $0.projectID, assetID: $0.assetID) }
                    accumulator.finish(index: index, source: source)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    let source: ScriptAssetDropSource? = data
                        .flatMap { String(data: $0, encoding: .utf8) }
                        .flatMap(URL.init(string:))
                        .map(ScriptAssetDropSource.fileURL)
                    accumulator.finish(index: index, source: source)
                }
            } else {
                accumulator.finish(index: index, source: nil)
            }
        }
    }
}

private final class ScriptAssetDropAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var sources: [Int: ScriptAssetDropSource] = [:]
    private let completion: @Sendable ([ScriptAssetDropSource]) -> Void

    init(count: Int, completion: @escaping @Sendable ([ScriptAssetDropSource]) -> Void) {
        remaining = count
        self.completion = completion
    }

    func finish(index: Int, source: ScriptAssetDropSource?) {
        lock.lock()
        if let source { sources[index] = source }
        remaining -= 1
        let isComplete = remaining == 0
        let ordered = isComplete ? sources.sorted { $0.key < $1.key }.map(\.value) : []
        lock.unlock()
        if isComplete { completion(ordered) }
    }
}
