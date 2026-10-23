import SwiftUI
import AppKit

struct ProjectVisualWorkspace: View {
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    @ObservedObject var materials: GlobalMaterialStore
    let onVersions: () -> Void
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var search = ""
    @State private var category = "全部"
    @State private var editing: CharacterLibraryStore.Loaded?
    private var index: ProjectWorkbenchIndex { service.workbenches[project.id] ?? .init() }
    private var episode: ProjectWorkbenchIndex.Episode? { index.episodes.first { $0.id == service.state.navigation.episodeID } }
    private var subjects: [ProjectWorkbenchIndex.Subject] {
        index.subjects.compactMap { original in
            var subject = original
            if let folder = service.state.navigation.sourceFolder {
                let ownSource = subject.sources.contains { path in
                    ProjectSourceFileIndex.contains(CharacterProjectModules.resolve(path, root: URL(fileURLWithPath: project.rootPath)).standardizedFileURL.path, in: folder)
                }
                subject.media = subject.media.filter { ProjectSourceFileIndex.contains($0.material.sourcePath ?? "", in: folder) }
                guard ownSource || !subject.media.isEmpty else { return nil }
            }
            guard
            (category == "全部" || subject.kind == category) &&
            (episode == nil || episode!.subjectIDs.contains(subject.id)) &&
            (search.isEmpty || (subject.name + subject.id).localizedCaseInsensitiveContains(search)) else { return nil }
            return subject
        }
    }
    private var selected: ProjectWorkbenchIndex.Subject? { subjects.first { $0.id == service.state.navigation.selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TextField("搜索人物、场景、道具…", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("资产分类", selection: $category) { ForEach(["全部", "人物", "场景", "道具", "服装", "其他"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                Button("造型与版本") { service.selectSourceFolder(nil); onVersions() }
            }.padding(14)
            HStack {
                Text(episode == nil ? "全剧资产中心" : "\(episode!.title) · 关联资产").font(.title3.bold())
                Text("\(subjects.count) 个主体").foregroundStyle(.secondary)
                Spacer()
                if episode != nil { Button("查看全剧") { service.selectEpisode(nil) } }
            }.padding(.horizontal, 16).padding(.bottom, 8)
            if episode != nil { Text("按稳定 ID 和明确来源链接关联；资料提及不代表该素材已被镜头采用。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(subjects) { subject in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { service.select(subject.id) } label: {
                                    HStack {
                                        Text(subject.name).font(.headline)
                                        Text(subject.kind + " · " + subject.id).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(subject.variants.count) 个图片/声音分组").font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: "sidebar.right")
                                    }
                                }.buttonStyle(.plain).accessibilityLabel("查看\(subject.name)档案")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                                    if subject.media.isEmpty {
                                        ProjectVisualCard(subject: subject, variant: "暂无关联图片", media: [], project: project, service: service, selected: selected?.id == subject.id) { service.select(subject.id) }
                                    } else {
                                        ForEach(subject.variants, id: \.self) { variant in
                                            ProjectVisualCard(subject: subject, variant: variant, media: subject.media.filter { $0.variant == variant }, project: project, service: service, selected: selected?.id == subject.id) { service.select(subject.id) }
                                        }
                                    }
                                }
                            }
                        }
                        if subjects.isEmpty {
                            ContentUnavailableView("暂无匹配资产", systemImage: "photo.on.rectangle", description: Text(episode == nil ? "检查分类与搜索；资产依据已有身份和来源关联，不需要重新填写。" : "本集尚无明确身份关联。可在文稿中查看原文，或切换全剧资产。"))
                        }
                    }.padding(16)
                }.frame(minWidth: 440)
                if let selected {
                    ProjectVisualDetails(subject: selected, project: project, index: index, service: service, materials: materials, onEdit: {
                        if var row = service.library.loaded.first(where: { $0.entry.projectID == project.id && $0.entry.characterID == selected.id }) {
                            for fact in selected.facts {
                                let name = fact.label == "身份" ? "一句话身份" : fact.label
                                if CharacterProfile.fieldNames.contains(name), row.profile?.fields[name]?.text.isEmpty != false {
                                    row.profile?.fields[name] = .init(text: fact.value, review: .candidate, evidence: fact.evidence)
                                }
                            }
                            editing = row
                        }
                    }).frame(minWidth: 300, idealWidth: 360, maxWidth: 450)
                }
            }
        }
        .onAppear { search = service.state.navigation.search; category = service.state.navigation.assetCategory ?? "全部" }
        .onChange(of: search) { _, value in service.setSearch(value) }
        .onChange(of: category) { _, value in service.selectCategory(value) }
        .sheet(item: $editing) { row in
            CharacterProfileEditor(library: service.library, materials: materials, loaded: row, onClose: { editing = nil; service.refresh() }).environmentObject(editGuard)
        }
    }
}

private struct ProjectVisualCard: View {
    let subject: ProjectWorkbenchIndex.Subject
    let variant: String
    let media: [ProjectWorkbenchIndex.Media]
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    let selected: Bool
    let action: () -> Void
    private var cover: ProjectWorkbenchIndex.Media? { media.first { $0.material.kind == .image && $0.exists } ?? media.first { $0.material.kind == .image } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                if let cover {
                    MaterialThumbnailView(material: cover.material, previewMaximumDimension: 600).frame(height: 175)
                } else {
                    ZStack { Rectangle().fill(Color(nsColor: .underPageBackgroundColor)); Label(media.contains { $0.material.kind == .audio } ? "声音资产" : "暂无关联图片", systemImage: "photo") }.frame(height: 175)
                }
            }.buttonStyle(.plain).accessibilityLabel("查看\(subject.name) · \(variant)")
            VStack(alignment: .leading, spacing: 8) {
                Text(variant).font(.headline).lineLimit(2)
                if let cover {
                    ProjectImageResolutionView(material: cover.material)
                    ProjectImagePromptLinks(media: cover, path: cover.material.sourcePath ?? "", project: project, service: service)
                }
                if subject.kind == "人物" {
                    ProjectAssetDocumentLinks(title: "人物介绍", paths: subject.introductionPaths, root: URL(fileURLWithPath: project.rootPath)) {
                        ProjectAssetDocumentLinks.choose(kind: "人物介绍", projectID: project.id, target: subject.id, service: service)
                    }
                }
                Text(subject.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let cover { Text(cover.exists ? cover.status : "图片文件失联").font(.caption).foregroundStyle(cover.exists ? Color.secondary : .orange).lineLimit(2) }
                Text("图片 \(media.filter { $0.material.kind == .image }.count) · 声音 \(media.filter { $0.material.kind == .audio }.count)").font(.caption)
                HStack {
                    Button("查看档案", action: action)
                    if let cover { Button("放大图片") { MaterialQuickLookController.shared.show(cover.material) }.disabled(!cover.exists) }
                }.controlSize(.small)
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProjectVisualDetails: View {
    let subject: ProjectWorkbenchIndex.Subject
    let project: CharacterLibraryRegistry.Project
    let index: ProjectWorkbenchIndex
    @ObservedObject var service: ProjectAutomationService
    @ObservedObject var materials: GlobalMaterialStore
    let onEdit: () -> Void
    private let labels = ["年龄", "性别", "身高", "体重", "身份", "外貌", "性格", "人物关系", "说话特点"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(subject.name).font(.title2.bold())
                Text(subject.id + " · " + subject.kind).foregroundStyle(.secondary)
                if subject.kind == "人物" {
                    ProjectAssetDocumentLinks(title: "人物介绍", paths: subject.introductionPaths, root: URL(fileURLWithPath: project.rootPath)) {
                        ProjectAssetDocumentLinks.choose(kind: "人物介绍", projectID: project.id, target: subject.id, service: service)
                    }
                }
                if let hero = subject.images.first(where: { $0.exists }) {
                    Button { MaterialQuickLookController.shared.show(hero.material) } label: {
                        MaterialThumbnailView(material: hero.material, previewMaximumDimension: 900).frame(height: 250)
                    }.buttonStyle(.plain).accessibilityLabel("放大\(subject.name)预览图")
                    Text("预览图 · " + hero.variant).font(.caption).foregroundStyle(.secondary)
                    ProjectImageResolutionView(material: hero.material)
                }
                if !subject.issue.isEmpty { Text(subject.issue).foregroundStyle(.orange).font(.caption) }
                if subject.kind == "人物" {
                    GroupBox("人物速览") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(labels, id: \.self) { label in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(label).font(.caption).foregroundStyle(.secondary)
                                    if let fact = subject.facts.first(where: { $0.label == label }) {
                                        Text(fact.value).textSelection(.enabled)
                                        DisclosureGroup("来源依据") { Text(fact.evidence).font(.caption).textSelection(.enabled); sourceButton(fact.source) }
                                    } else { Text("待补充").foregroundStyle(.tertiary) }
                                }
                            }
                            Button("编辑人物档案…", action: onEdit)
                        }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox("声音试听") {
                    VStack(alignment: .leading, spacing: 12) {
                        if subject.audio.isEmpty { Text("尚无明确关联的音频；声线文字设定不等于已有声音文件。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(subject.audio) { item in ProjectAudioPreview(media: item) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
                Text("图像与其他素材 · \(subject.media.count)").font(.headline)
                ForEach(subject.media.filter { $0.material.kind != .audio }) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        if item.material.kind == .image {
                            Button { MaterialQuickLookController.shared.show(item.material) } label: {
                                MaterialThumbnailView(material: item.material, previewMaximumDimension: 900).frame(height: 210)
                            }.buttonStyle(.plain).disabled(!item.exists).accessibilityLabel("预览\(item.material.name)")
                        }
                        Text(item.variant).font(.headline)
                        Text(item.material.name).font(.caption).textSelection(.enabled)
                        Text(item.exists ? item.status : "文件失联").font(.caption).foregroundStyle(.secondary)
                        Text("用途：" + item.role).font(.caption)
                        if item.material.kind == .image {
                            ProjectImageResolutionView(material: item.material)
                            ProjectImagePromptLinks(media: item, path: item.material.sourcePath ?? "", project: project, service: service)
                        }
                        if let bytes = item.material.fileSize { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption) }
                        DisclosureGroup("提示词与来源") {
                            Text("原始生成提示词").font(.headline)
                            Text(item.prompt.isEmpty ? "待补充；不会用整理后的模板代替生成原文。" : item.prompt).textSelection(.enabled)
                            if !item.prompt.isEmpty { Button("复制原始提示词") { copy(item.prompt) } }
                            if !item.reuse.isEmpty { Text("复用模板").font(.headline); Text(item.reuse).textSelection(.enabled); Button("复制复用模板") { copy(item.reuse) } }
                            Text(item.evidence).font(.caption).textSelection(.enabled)
                            sourceButton(item.source)
                            Text(item.material.sourcePath ?? "").font(.caption2).textSelection(.enabled)
                        }
                        Button("复制具体文件路径") { copy(item.material.sourcePath ?? "") }
                        Divider()
                    }
                }
                GroupBox("关联分集与已用镜头") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(index.episodes.filter { $0.subjectIDs.contains(subject.id) }) { ep in Text(ep.title + " · 资料关联").font(.caption) }
                        let used = materials.links.filter { $0.projectID == project.id && $0.subjectID == subject.id }
                        ForEach(used) { link in Text([link.episode, link.scene, link.shot].compactMap { $0 }.joined(separator: " / ") + " · 固定素材 " + link.materialID).font(.caption).textSelection(.enabled) }
                        if used.isEmpty { Text("尚无已登记的镜头采用记录").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("全部资料来源") { ForEach(subject.sources.sorted(), id: \.self) { sourceButton($0) } }
            }.padding(16)
        }.id(subject.id)
    }
    private func sourceButton(_ path: String) -> some View {
        Button(URL(fileURLWithPath: path).lastPathComponent) { NSWorkspace.shared.open(CharacterProjectModules.resolve(path, root: URL(fileURLWithPath: project.rootPath))) }.font(.caption)
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
