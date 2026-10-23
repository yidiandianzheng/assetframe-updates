import SwiftUI
import AppKit

struct ProjectDocumentsView: View {
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var category = "全部文稿"
    private var index: ProjectWorkbenchIndex { service.workbenches[project.id] ?? .init() }
    private var episode: ProjectWorkbenchIndex.Episode? { index.episodes.first { $0.id == service.state.navigation.episodeID } }
    private var documents: [CharacterProjectDocument] {
        index.documents.filter { doc in
            let narrative = ["项目入口", "项目大纲", "剧集索引", "剧情正文", "分镜记录", "制作接口"].contains(doc.kind)
            let explicitlyOpened = doc.path == service.state.navigation.documentPath
            let folder = service.state.navigation.sourceFolder
            let absolute = CharacterProjectModules.resolve(doc.path, root: URL(fileURLWithPath: project.rootPath)).standardizedFileURL.path
            return (narrative || explicitlyOpened) && (!ProjectWorkbenchIndex.isHistorical(doc.path) || explicitlyOpened) &&
                (folder == nil || ProjectSourceFileIndex.contains(absolute, in: folder!)) && (episode == nil || episode!.paths.contains(doc.path)) &&
                (category == "全部文稿" || doc.kind == category)
        }.sorted { a, b in
            let aEntry = a.path.hasSuffix("生产卡.md"), bEntry = b.path.hasSuffix("生产卡.md")
            return aEntry != bEntry ? aEntry : a.path < b.path
        }
    }
    private var selected: CharacterProjectDocument? { documents.first { $0.path == service.state.navigation.documentPath } ?? documents.first }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Picker("文稿类型", selection: $category) { ForEach(["全部文稿", "项目大纲", "剧情正文", "剧集索引", "项目入口", "分镜记录", "制作接口"], id: \.self) { Text($0).tag($0) } }.padding(10)
                List(selection: Binding(get: { selected?.path }, set: { path in if let path { editGuard.request { service.selectDocument(path) } } })) {
                    ForEach(documents) { doc in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(ProjectWorkbenchIndex.title(doc)).lineLimit(2)
                            Text(doc.kind + (doc.path.contains("候选") ? " · 候选" : "")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(doc.path)
                    }
                }
                Text("\(documents.count) 份原文 · 章与集分别保留").font(.caption).foregroundStyle(.secondary).padding(10)
            }.frame(minWidth: 220, idealWidth: 270, maxWidth: 340)
            if let selected {
                ProjectDocumentEditor(project: project, document: selected, service: service).id(project.id + selected.path)
            } else { ContentUnavailableView("没有匹配的文稿", systemImage: "doc.text", description: Text("请选择其他类型，或从侧栏返回全剧资料。")) }
        }
    }
}

private struct ProjectDocumentEditor: View {
    let project: CharacterLibraryRegistry.Project
    let document: CharacterProjectDocument
    @ObservedObject var service: ProjectAutomationService
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var text = ""
    @State private var original = ""
    @State private var expected = ""
    @State private var editing = false
    @State private var preview = false
    @State private var notice = ""
    @State private var initialized = false
    private var key: String { project.id + "|" + document.path }
    private var url: URL { CharacterProjectModules.resolve(document.path, root: URL(fileURLWithPath: project.rootPath)) }
    private var dirty: Bool { text != original }
    private var readOnly: Bool { document.kind == "制作接口" || document.path.contains("自动组装") || document.text.contains("不手改") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ProjectWorkbenchIndex.title(document)).font(.title3.bold()).lineLimit(2)
                Spacer()
                Button("打开原文件") { NSWorkspace.shared.open(url) }
                if !readOnly { Button(editing ? "阅读" : "编辑 MD") { editing.toggle() } }
                Button("预览写回") { preview = true }.disabled(!dirty || readOnly)
            }
            Text(document.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if document.fingerprint != expected && initialized { Text("来源已变化；当前草稿保留，写回前需核对。").font(.caption).foregroundStyle(.orange) }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if readOnly { Text("制作接口或自动组装文档：只读查看，请通过其原有生产入口修改。").font(.caption).foregroundStyle(.secondary) }
            if editing { TextEditor(text: $text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden) }
            else {
                ScrollView {
                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text(dirty ? "草稿保留在资源库；原文尚未改变" : "读取项目原 MD").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新读取原文") { editGuard.request { reload() } }
            }
        }.padding(16).frame(minWidth: 440)
        .onAppear {
            reload()
            if let draft = service.state.documentDrafts?[key] { text = draft.text; expected = draft.expected; editing = true }
            initialized = true; configureGuard()
        }
        .onChange(of: text) { _, _ in if initialized { configureGuard() } }
        .task(id: text) {
            guard initialized else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            persist()
        }
        .onChange(of: document.fingerprint) { _, _ in if !dirty { reload() } }
        .onDisappear { persist(); editGuard.dirty = false; editGuard.save = nil; editGuard.discard = nil }
        .sheet(isPresented: $preview) {
            VStack(alignment: .leading, spacing: 14) {
                Text("写回原 MD 前核对").font(.title2.bold())
                Text("将保存到：" + url.path).font(.caption).textSelection(.enabled)
                Text("保存前核对原文指纹，并在原文件旁保留完整备份。")
                HSplitView {
                    ScrollView { Text(original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(10)
                    ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(10)
                }
                HStack { Text("左：开始编辑时的原文　右：当前草稿").font(.caption); Spacer(); Button("返回编辑") { preview = false }; Button("确认写回并备份") { if save() { preview = false } }.buttonStyle(.borderedProminent) }
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(20).frame(width: 900, height: 620)
        }
    }
    private func reload() {
        do { let value = try CharacterMarkdown.read(url); original = value.0; text = value.0; expected = value.1; notice = "" }
        catch { notice = error.localizedDescription }
        configureGuard()
    }
    private func persist() {
        guard initialized else { return }
        let draft = dirty ? ProjectAutomationState.WritebackDraft(id: key, path: url.path, expected: expected, text: text) : nil
        if !service.preserveDocument(draft, key: key) { notice = "草稿暂未保存到资源库，请保留此窗口或复制内容。" }
    }
    private func configureGuard() {
        editGuard.dirty = dirty
        // Navigation may keep the persisted draft, but cannot silently write a project document.
        editGuard.save = { persist(); return service.state.documentDrafts?[key]?.text == text }
        editGuard.discard = { text = original; _ = service.preserveDocument(nil, key: key) }
    }
    private func save() -> Bool {
        guard !readOnly else { return false }
        do {
            let backup = try CharacterMarkdown.save(text, to: url, expected: expected)
            original = text; expected = CharacterMarkdown.fingerprint(Data(text.utf8)); editGuard.dirty = false
            _ = service.preserveDocument(nil, key: key); notice = "已保存，备份：" + backup.lastPathComponent
            service.refresh(); return true
        } catch { notice = error.localizedDescription; persist(); return false }
    }
}
