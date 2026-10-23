import SwiftUI

/// Eagle-style single inspector. Everyday organization stays visible while
/// AI-video provenance and shot usage remain available in compact disclosures.
struct MaterialProductionInspector: View {
    @ObservedObject var store: GlobalMaterialStore
    let material: MaterialRecord
    let project: ProjectRecord
    var sourceAvailability: MaterialSourceAvailability? = nil
    var editGuard: InspectorEditGuard? = nil
    var onUse: ((Double?, Double?) -> Void)? = nil
    var onRelocated: (@MainActor () -> Void)? = nil
    @State private var savedFields: [String] = []
    @State private var initialized = false
    @State private var saving = false
    @State private var saveError: String?

    @State private var name = ""
    @State private var tags = ""
    @State private var note = ""
    @State private var source = ""
    @State private var production = MaterialProductionMetadata()
    @State private var inputs = ""
    @State private var parentID = ""
    @State private var versionSearch = ""
    @State private var productionExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                preview
                colorPicker
                TextField("素材名称", text: $name).font(.headline)
                TextField("添加备注", text: $note, axis: .vertical).lineLimit(2...5)

                sectionTitle("标签")
                TextField("添加标签，用逗号分隔", text: $tags)

                Divider()
                sectionTitle("分类")
                MaterialClassificationEditor(store: store, material: material)

                Divider()
                sectionTitle("整理")
                Picker("旧版类型（兼容）", selection: Binding(
                    get: { material.assetType ?? .unclassified },
                    set: { type in store.update(material.id) { $0.assetType = type } }
                )) {
                    ForEach(AssetType.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("AI 整理与旧筛选使用的粗类型；新分类请使用上方受控词表")
                Picker("用途", selection: $production.purpose) {
                    ForEach(Self.purposes, id: \.self) { Text($0) }
                }
                Picker("审核", selection: $production.review) {
                    ForEach(Self.reviews, id: \.self) { Text($0) }
                }
                HStack {
                    Text("评分")
                    Spacer()
                    MaterialRatingControl(store: store, material: material, project: project)
                }
                Button {
                    store.makeCommon([material.id], project: project)
                } label: {
                    Label(
                        material.production?.isCommon == true ? "补齐通用资产副本" : "加入通用资产",
                        systemImage: material.production?.isCommon == true ? "checkmark.circle.fill" : "archivebox"
                    ).frame(maxWidth: .infinity)
                }
                .disabled(store.managedCopyJobs > 0)

                Button(saving ? "正在保存…" : "保存信息", systemImage: "checkmark") { Task { _ = await saveAll() } }
                    .disabled(saving)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut("s", modifiers: [.command])

                if initialized && draftFields != savedFields { Text("有未保存的修改").font(.caption).foregroundStyle(.orange) }
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
                Divider()
                sectionTitle("基本信息")
                metadata
                fileActions
                if material.kind != .link {
                    Button("重新定位原文件…") {
                        if let editGuard { editGuard.request { store.relocate(material.id, onComplete: onRelocated) } }
                        else { store.relocate(material.id, onComplete: onRelocated) }
                    }
                }
                if let onUse {
                    Button("选用此版本并加入交付") { onUse(nil, nil) }
                    let usages = store.links.filter { $0.materialID == material.id && $0.projectID == project.id && $0.selection == "选用" }
                    ForEach(usages) { usage in
                        HStack {
                            Text([usage.episode, usage.scene, usage.shot].compactMap { $0 }.joined(separator: " / ").isEmpty ? "整份素材已选用" : [usage.episode, usage.scene, usage.shot].compactMap { $0 }.joined(separator: " / "))
                                .font(.caption)
                            Button("移除引用") { store.removeUsage(usage.id) }.font(.caption)
                        }
                    }
                }

                if let duplicateID = material.duplicateContentOf { duplicateNotice(duplicateID) }

                Divider()
                DisclosureGroup("AI 视频生产信息", isExpanded: $productionExpanded) {
                    provenance.padding(.top, 10)
                }
            }
            .padding(12)
            .textFieldStyle(.roundedBorder)
        }
        .disabled(!store.canWrite || saving)
        .task(id: material.id) { reloadSavedMaterial() }
        .onChange(of: material) { _, _ in
            // Tag adoption and version association can update the selected record
            // while this inspector stays mounted. Only refresh a clean draft.
            guard initialized, !saving, draftFields == savedFields else { return }
            reloadSavedMaterial()
        }
        .onChange(of: draftFields) { _, _ in registerDraft() }
    }

    private func reloadSavedMaterial() {
        name = material.name
        tags = material.tags.joined(separator: ", ")
        note = material.note
        source = material.sourceURL ?? ""
        production = material.production ?? MaterialProductionMetadata()
        inputs = production.inputMaterialIDs.joined(separator: ", ")
        parentID = ""
        savedFields = draftFields
        initialized = true
        registerDraft()
    }

    private var draftFields: [String] {
        [name, tags, note, source, inputs, parentID, production.purpose, production.review,
         production.versionName, production.platform, production.model, production.batch,
         production.prompt, production.licenseNote]
    }

    private func registerDraft() {
        guard initialized, let editGuard else { return }
        editGuard.dirty = draftFields != savedFields
        editGuard.save = { await saveAll() }
        editGuard.discard = {
            name = material.name; tags = material.tags.joined(separator: ", ")
            note = material.note; source = material.sourceURL ?? ""
            production = material.production ?? MaterialProductionMetadata()
            inputs = production.inputMaterialIDs.joined(separator: ", ")
            parentID = ""
            savedFields = draftFields
        }
    }

    private func saveAll() async -> Bool {
        guard store.canWrite, !saving else { return false }
        saving = true
        defer { saving = false }
        let fields = draftFields
        let cleanTags = tags.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let inputIDs = inputs.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let draft = production, draftName = name, draftNote = note, draftSource = source
        guard store.materials.contains(where: { $0.id == material.id }) else { return false }
        store.update(material.id) { item in
            item.name = draftName; item.note = draftNote; item.tags = Array(Set(cleanTags)).sorted()
            item.sourceURL = draftSource.isEmpty ? nil : draftSource
            var value = item.production ?? MaterialProductionMetadata()
            value.purpose = draft.purpose; value.review = draft.review
            value.versionName = draft.versionName; value.platform = draft.platform
            value.model = draft.model; value.batch = draft.batch; value.prompt = draft.prompt
            value.inputMaterialIDs = inputIDs; value.licenseNote = draft.licenseNote
            item.production = value
        }
        if !parentID.isEmpty { store.setVersion(material.id, relativeTo: parentID) }
        switch await store.saveNow() {
        case .success:
            savedFields = fields
            saveError = nil
            registerDraft()
            store.toast = "素材信息已保存"
            return true
        case .failure(let error):
            saveError = error.localizedDescription
            return false
        }
    }

    @ViewBuilder private var preview: some View {
        if material.kind == .audio || material.kind == .video {
            MaterialPlayerView(material: material, cacheRoot: SSDPreviewCache.directory("MediaAnalysis"), onCover: { seconds in
                store.update(material.id) {
                    var value = $0.production ?? MaterialProductionMetadata()
                    value.coverSeconds = seconds
                    $0.production = value
                }
                production.coverSeconds = seconds
            }, onRange: { start, end in onUse?(start, end) })
        } else {
            MaterialThumbnailView(material: material)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 7) {
            Spacer()
            colorButton(nil, color: Color(nsColor: .controlBackgroundColor))
            colorButton("红色", color: .red)
            colorButton("橙色", color: .orange)
            colorButton("黄色", color: .yellow)
            colorButton("绿色", color: .green)
            colorButton("蓝色", color: .blue)
            colorButton("紫色", color: .purple)
            colorButton("灰色", color: .gray)
            Spacer()
        }.padding(.vertical, 6)
    }

    private func colorButton(_ label: String?, color: Color) -> some View {
        let selected = material.colorLabel == label
        return Button {
            store.update(material.id) { $0.colorLabel = label }
        } label: {
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay(Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .help(label ?? "清除颜色标记")
        .accessibilityLabel(label ?? "无颜色标记")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow("类型", material.kind.rawValue)
            infoRow("格式", (material.originalFilename as NSString).pathExtension.uppercased())
            infoRow("文件大小", material.fileSize?.formatted(.byteCount(style: .file)) ?? "尚未读取")
            if let width = material.mediaMetadata?.pixelWidth, let height = material.mediaMetadata?.pixelHeight { infoRow("尺寸", "\(width) × \(height)") }
            if let duration = material.mediaMetadata?.durationSeconds { infoRow("时长", MaterialThumbnailView.durationText(duration)) }
            infoRow("添加日期", material.createdAt.formatted(date: .numeric, time: .shortened))
            if let created = material.sourceCreatedAt { infoRow("创建日期", created.formatted(date: .numeric, time: .shortened)) }
            if let modified = material.sourceModifiedAt { infoRow("修改日期", modified.formatted(date: .numeric, time: .shortened)) }
            if let status = sourceAvailability, status != .available {
                Label(status.rawValue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(status == .offline ? "重新连接磁盘后刷新；记录与标签保留" : status == .cloudOnly ? "可在 Finder 中下载原文件后刷新" : status == .unreadable ? "检查文件访问权限后刷新" : "重新定位原文件后可恢复访问")
                    .foregroundStyle(.secondary)
            }
            Text(fileStatus).font(.caption).foregroundStyle(material.sourceMissing ? .orange : .secondary).lineLimit(3).textSelection(.enabled)
        }.font(.callout)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var fileActions: some View {
        HStack {
            Button(material.kind == .link ? "打开链接" : "打开原文件", systemImage: "arrow.up.forward.app") { store.open(material) }
            Button("在 Finder 中显示", systemImage: "folder") { if let location = material.fileLocation { store.reveal(location) } }
                .disabled(material.fileLocation?.exists != true)
            Button("系统预览", systemImage: "eye") { MaterialQuickLookController.shared.show(material) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private func duplicateNotice(_ duplicateID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发现内容重复，两个版本均已保留").foregroundStyle(.orange)
            if let original = store.materials.first(where: { $0.id == duplicateID }) { Button("查看另一份原文件") { store.open(original) } }
            Button("确认保留两份") { store.update(material.id) { $0.duplicateContentOf = nil } }
        }.font(.caption)
    }

    private var parentCandidates: [MaterialRecord] {
        guard versionSearch.count >= 2 else { return [] }
        return Array(store.materials.lazy.filter {
            $0.kind == material.kind && $0.id != material.id && ($0.name.localizedCaseInsensitiveContains(versionSearch) || $0.id.localizedCaseInsensitiveContains(versionSearch))
        }.prefix(40))
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("版本名称", text: $production.versionName)
            TextField("搜索已有素材名称或 ID（至少 2 字）", text: $versionSearch).onChange(of: versionSearch) { _, _ in parentID = "" }
            Picker("关联版本", selection: $parentID) {
                Text("不修改版本组").tag("")
                ForEach(parentCandidates) { Text($0.name).tag($0.id) }
            }
            TextField("生成平台", text: $production.platform)
            TextField("模型", text: $production.model)
            TextField("批次", text: $production.batch)
            TextField("提示词", text: $production.prompt, axis: .vertical)
            TextField("输入素材 ID（逗号分隔）", text: $inputs)
            TextField("来源网址", text: $source)
            TextField("授权备注", text: $production.licenseNote, axis: .vertical)
            Button("保存生产信息") { Task { _ = await saveAll() } }.disabled(saving)
            Text("素材 ID：\(material.id)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var fileStatus: String {
        guard let path = material.sourcePath else { return material.sourceURL ?? "文件缺失" }
        if !FileManager.default.fileExists(atPath: path) {
            if path.hasPrefix("/Volumes/"), let volume = path.split(separator: "/").dropFirst().first, !FileManager.default.fileExists(atPath: "/Volumes/" + volume) { return "磁盘离线：" + path }
            return "文件缺失：" + path
        }
        if !FileManager.default.isReadableFile(atPath: path) { return "无读取权限：" + path }
        return path
    }

    static let purposes = ["未指定", "配音", "BGM", "音效", "环境声", "生成镜头", "参考片", "角色参考", "场景参考", "道具参考"]
    static let reviews = ["待审核", "保留", "备用", "返工", "淘汰"]
}
