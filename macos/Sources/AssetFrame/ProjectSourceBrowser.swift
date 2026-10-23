import SwiftUI
import AppKit

struct ProjectSourceTree: View {
    let folders: [ProjectSourceFileIndex.Folder]
    let selected: String?
    let select: (String) -> Void
    var body: some View {
        ForEach(folders) { folder in
            ProjectSourceFolderRow(folder: folder, selected: selected, depth: 0, select: select)
        }
    }
}

private struct ProjectSourceFolderRow: View {
    let folder: ProjectSourceFileIndex.Folder
    let selected: String?
    let depth: Int
    let select: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                if folder.children != nil {
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption) }
                        .buttonStyle(.plain).frame(width: 16)
                        .accessibilityLabel((expanded ? "折叠" : "展开") + folder.name)
                } else { Color.clear.frame(width: 16, height: 16).accessibilityHidden(true) }
                Button { select(folder.path) } label: {
                HStack(spacing: 5) {
                    Image(systemName: folder.issue.isEmpty ? "folder" : "folder.badge.questionmark")
                    Text(folder.name).lineLimit(1)
                }.foregroundStyle(folder.issue.isEmpty ? Color.primary : .orange)
                    .padding(.vertical, 4).padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected == folder.path ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).help(folder.path + (folder.issue.isEmpty ? "" : "\n" + folder.issue))
                .accessibilityLabel("来源文件夹：" + folder.name)
            }.padding(.leading, CGFloat(depth) * 14)
            if expanded {
                ForEach(folder.children ?? []) { child in
                    ProjectSourceFolderRow(folder: child, selected: selected, depth: depth + 1, select: select)
                }
            }
        }
        .onAppear { revealSelection() }
        .onChange(of: selected) { _, _ in revealSelection() }
    }
    private func revealSelection() {
        if let selected, selected != folder.path, ProjectSourceFileIndex.contains(selected, in: folder.path) { expanded = true }
    }
}

struct ProjectSourceBrowser: View {
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var search = ""
    private var index: ProjectWorkbenchIndex { service.workbenches[project.id] ?? .init() }
    private var folder: String? { service.state.navigation.sourceFolder }
    private var files: [ProjectSourceFileIndex.File] {
        index.fileIndex.files.filter { file in
            (folder == nil || URL(fileURLWithPath: file.path).deletingLastPathComponent().path == folder) &&
            (search.isEmpty || file.name.localizedCaseInsensitiveContains(search))
        }
    }
    private var childFolders: [ProjectSourceFileIndex.Folder] {
        func find(_ nodes: [ProjectSourceFileIndex.Folder]) -> ProjectSourceFileIndex.Folder? {
            for node in nodes {
                if node.path == folder { return node }
                if let match = find(node.children ?? []) { return match }
            }
            return nil
        }
        return folder == nil ? index.fileIndex.roots : find(index.fileIndex.roots)?.children ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "所有链接目录").font(.title3.bold())
                Spacer()
                TextField("搜索当前文件列表…", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 270)
                if let folder { Button("在访达显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) } }
            }
            Text("按原目录浏览文件；统一资产身份、造型与提示词在“资产”中查看。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(childFolders) { node in
                        Button { editGuard.request { service.selectSourceFolder(node.path) } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "folder.fill").font(.system(size: 42)).foregroundStyle(.yellow).frame(height: 80)
                                Text(node.name).lineLimit(2)
                                if !node.issue.isEmpty { Text(node.issue).font(.caption).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }.buttonStyle(.bordered).help(node.path)
                    }
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { open(file) } label: {
                                if let material = file.material {
                                    MaterialThumbnailView(material: material, previewMaximumDimension: 500).frame(height: 140)
                                } else {
                                    Image(systemName: "doc.text").font(.system(size: 38)).frame(maxWidth: .infinity).frame(height: 140)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("打开文件：" + file.name)
                            Text(file.name).lineLimit(2).textSelection(.enabled)
                            Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            if let raw = file.material, raw.kind == .image {
                                let context = index.imageContexts[file.path]
                                ProjectImageResolutionView(material: context?.media.material ?? raw)
                                ProjectImagePromptLinks(media: context?.media, path: file.path, project: project, service: service)
                                if let context, !context.introductionPaths.isEmpty {
                                    ProjectAssetDocumentLinks(title: "人物介绍", paths: context.introductionPaths, root: URL(fileURLWithPath: project.rootPath))
                                }
                            }
                            HStack {
                                Button("打开") { open(file) }
                                Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
                            }.controlSize(.small)
                        }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).help(file.path)
                    }
                }
                if files.isEmpty && childFolders.isEmpty {
                    ContentUnavailableView(project.sources.isEmpty ? "尚未链接目录" : "此文件夹没有匹配文件", systemImage: "folder", description: Text("在项目下点击“添加链接目录…”，可以一次选择多个位置。"))
                }
            }
            Text("\(files.count) 个文件 · \(childFolders.count) 个子目录").font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
    private func open(_ file: ProjectSourceFileIndex.File) {
        if let doc = index.documents.first(where: { CharacterProjectModules.resolve($0.path, root: URL(fileURLWithPath: project.rootPath)).standardizedFileURL.path == file.path }) {
            editGuard.request {
                service.selectDocument(doc.path)
                service.navigate(project: project.id, section: "文稿")
            }
        } else if let material = file.material { MaterialQuickLookController.shared.show(material) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
    }
}
