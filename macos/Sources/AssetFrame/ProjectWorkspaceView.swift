import SwiftUI
import AppKit

struct ProjectWorkspaceView: View {
    @ObservedObject var session: LibrarySession
    @ObservedObject var service: ProjectAutomationService
    @ObservedObject var materials: GlobalMaterialStore
    @Binding var showLibraryManager: Bool
    @Binding var showLibraryPanel: Bool
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @Binding var projectManagement: ProjectManagementRoute?
    var standalone = false
    @State private var settings = false
    @State private var editingVersions = false
    @State private var writing: CharacterLibraryRegistry.Project?
    @State private var managingSources: CharacterLibraryRegistry.Project?
    private let sections = ["概览", "文件", "文稿", "资产", "待核对", "镜头"]
    private var project: CharacterLibraryRegistry.Project? { service.library.registry.projects.first { $0.id == service.state.navigation.projectID } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                if standalone {
                    Label("向量·剧坊", systemImage: "book.closed").font(.title3.bold())
                } else {
                    Button { editGuard.request { showLibraryPanel = true } } label: {
                        Label(session.descriptor?.name ?? "资源库", systemImage: "externaldrive")
                    }.buttonStyle(.bordered).accessibilityLabel("切换资源库")
                    Button("全部素材", systemImage: "photo.on.rectangle") { route("", "全部素材") }
                }
                Divider()
                HStack {
                    Text("项目").font(.headline)
                    Spacer()
                    Button("管理…") { editGuard.request { projectManagement = .manage } }
                }
                Button("新建项目…", systemImage: "plus") { editGuard.request { projectManagement = .create } }
                    .buttonStyle(.borderedProminent)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(service.library.registry.projects) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Button(item.name) { route(item.id, "概览") }.font(.headline)
                                if project?.id == item.id {
                                    Divider().padding(.vertical, 6)
                                    HStack {
                                        Text("链接目录").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button { managingSources = item } label: { Image(systemName: "plus") }
                                            .buttonStyle(.plain).accessibilityLabel("为\(item.name)添加链接目录")
                                    }
                                    ProjectSourceTree(folders: service.workbenches[item.id]?.fileIndex.roots ?? [], selected: service.state.navigation.sourceFolder) { path in
                                        editGuard.request { service.selectSourceFolder(path); service.navigate(project: item.id, section: "文件") }
                                    }
                                    Button("添加链接目录…") { managingSources = item }.font(.caption)
                                    Divider().padding(.vertical, 6)
                                    Button("全剧资料与资产") { editGuard.request { service.selectEpisode(nil) } }.font(.caption)
                                    ForEach(service.workbenches[item.id]?.episodes ?? []) { episode in
                                        Button {
                                            editGuard.request {
                                                let section = ["文稿", "资产"].contains(service.state.navigation.section) ? service.state.navigation.section : "文稿"
                                                service.selectEpisode(episode.id)
                                                service.navigate(project: item.id, section: section)
                                            }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(episode.title).font(.headline)
                                                Text(episode.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                                .background(service.state.navigation.episodeID == episode.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Text(service.activity.isEmpty ? "本地资料随项目变化检查" : service.activity).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("连接设置…", systemImage: "gearshape") { settings = true }
            }.padding(12).frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
            Group {
                if let project {
                    projectContent(project)
                } else if !standalone && service.state.navigation.section == "全部素材" {
                    UnifiedMaterialBrowser(session: session, store: materials, showLibraryPanel: $showLibraryPanel)
                } else {
                    ContentUnavailableView {
                        Label("接入项目，开始整理", systemImage: "folder.badge.plus")
                    } description: { Text("先新建项目，再为它链接一个或多个资料目录。目录保持原来的文件夹层级。") }
                    actions: { Button("新建项目…") { projectManagement = .create } }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $projectManagement) { destination in
            ProjectManagementSheet(service: service, library: service.library, materials: materials,
                libraryName: session.descriptor?.name ?? "当前资源库", initial: destination,
                onClose: { projectManagement = nil })
        }
        .sheet(isPresented: $settings) {
            DeepSeekSettingsView(task: .characterOrganization, startsAfterSave: false,
                usageDescription: "配置只保存一次。仅已开启自动整理的项目会发送必要文字；服务地址改变后，需要在项目概览重新开启。",
                onSave: { _ in settings = false; service.refresh() }, onCancel: { settings = false })
        }
        .sheet(item: $writing) { project in
            ProjectWorkspaceWriteback(project: project, service: service, onClose: { writing = nil; service.refresh() }).environmentObject(editGuard)
        }
        .sheet(item: $managingSources) { project in
            ProjectSourceManager(projectID: project.id, service: service, onClose: { managingSources = nil })
        }
    }
    private func route(_ project: String, _ section: String) {
        editGuard.request { editingVersions = false; service.navigate(project: project, section: section) }
    }
    @ViewBuilder private func projectContent(_ project: CharacterLibraryRegistry.Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) { Text(project.name).font(.title2.bold()); Text(service.state.navigation.section).foregroundStyle(.secondary) }
                Spacer()
                if !service.activity.isEmpty { ProgressView().controlSize(.small) }
                Button("检查变化", systemImage: "arrow.clockwise") { service.refresh() }
            }.padding(16)
            if let error = service.error { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled).padding(.horizontal, 16) }
            HStack(spacing: 16) {
                ForEach(sections, id: \.self) { section in
                    Button(section) { route(project.id, section) }
                        .buttonStyle(.bordered)
                        .tint(service.state.navigation.section == section ? .accentColor : .secondary)
                }
                Spacer()
                if let episode = service.state.navigation.episodeID { Text(episode + " · 本集").font(.caption); Button("全剧") { editGuard.request { service.selectEpisode(nil) } } }
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            if let folder = service.state.navigation.sourceFolder, ["文件", "文稿", "资产"].contains(service.state.navigation.section) {
                HStack {
                    Label(URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder")
                    Text(folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("所有目录") { editGuard.request { service.selectSourceFolder(nil) } }
                }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if editingVersions || service.state.navigation.section == "镜头" {
                ProjectAssetWorkspace(project: project, library: service.library, materials: materials,
                    category: ["人物", "场景", "道具", "服装"].contains(service.state.navigation.section) ? service.state.navigation.section : "人物", embedded: true,
                    onClose: { editingVersions = false; service.navigate(project: project.id, section: "概览"); service.refresh() }).id(project.id + service.state.navigation.section)
            } else if service.state.navigation.section == "概览" {
                overview(project)
            } else if service.state.navigation.section == "文稿" {
                ProjectDocumentsView(project: project, service: service)
            } else if service.state.navigation.section == "文件" {
                ProjectSourceBrowser(project: project, service: service)
            } else if service.state.navigation.section != "待核对" {
                ProjectVisualWorkspace(project: project, service: service, materials: materials, onVersions: { editingVersions = true })
            } else {
                ProjectWorkspaceResults(project: project, service: service, materials: materials,
                    section: service.state.navigation.section, onVersions: { editingVersions = true })
            }
        }
    }
    private func overview(_ project: CharacterLibraryRegistry.Project) -> some View {
        let jobs = service.jobs(project: project.id)
        let report = service.library.reports[project.id]
        let enabled = service.state.permissions[project.id]?.enabled == true
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("自动整理") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(enabled ? "已开启：软件打开期间自动整理此项目的新资料与变化。" : "尚未开启：标准记录仍直接读取，旧资料暂不发送给 AI。")
                        Text("范围：\(project.sources.count) 个链接目录").font(.caption)
                        ForEach(project.sources) { source in Text(source.path).font(.caption).textSelection(.enabled) }
                        Button("管理链接目录…") { managingSources = project }
                        Text(service.connection).font(.caption)
                        HStack {
                            Button(enabled ? "暂停自动整理" : "开启此项目自动整理") { service.enable(project.id, enabled: !enabled) }
                            Button("重试失败／中断任务") { service.retry() }
                        }
                        Text("AI 结果附原文依据；不会自动改写正文或确认资产。首次接入后无需逐人、逐文件选择。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                HStack(spacing: 24) {
                    metric("已读取", report?.documents.count ?? 0)
                    metric("待整理", jobs.filter { $0.status == "待整理" || $0.status == "整理中" }.count)
                    metric("整理完成", jobs.filter { ["整理完成", "已采用"].contains($0.status) }.count)
                    metric("待核对", jobs.filter { ["待核对", "失败", "待重试"].contains($0.status) }.count)
                }
                HStack(spacing: 24) {
                    metric("有效确认", service.library.loaded.filter { $0.entry.projectID == project.id }.flatMap(\.receipts).count)
                    metric("已用于制作", materials.links.filter { $0.projectID == project.id }.count)
                }
                if let report, !report.warnings.isEmpty {
                    DisclosureGroup("读取与关联提示 · \(report.warnings.count) 项（结果可能不完整）") {
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).textSelection(.enabled) }
                    }.foregroundStyle(.orange)
                }
                if let fileIndex = service.workbenches[project.id]?.fileIndex, !fileIndex.warnings.isEmpty {
                    DisclosureGroup("目录读取提示 · \(fileIndex.warnings.count) 项") {
                        ForEach(Array(fileIndex.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).textSelection(.enabled) }
                    }.foregroundStyle(.orange)
                }
                if let resources = service.resources[project.id], !resources.isEmpty {
                    DisclosureGroup("已有资源索引 · \(resources.count) 项") {
                        ForEach(resources) { resource in
                            HStack {
                                Text(resource.id).font(.caption)
                                Text(resource.status).font(.caption).foregroundStyle(resource.status.hasPrefix("指纹一致") ? Color.secondary : .orange)
                                Spacer()
                                Button("查看文件") { NSWorkspace.shared.open(URL(fileURLWithPath: resource.path)) }.disabled(resource.status == "文件失联")
                                Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resource.path, forType: .string) }
                            }
                        }
                    }
                }
                GroupBox("最近资料与处理结果") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(jobs.prefix(20)) { job in
                            HStack { Text(URL(fileURLWithPath: job.path).lastPathComponent); Spacer(); Text(job.status).foregroundStyle(.secondary) }
                        }
                        if jobs.isEmpty { Text("当前没有需要 AI 整理的旧资料。标准记录可在资产分类中查看。") }
                    }.padding(6)
                }
                Button("预览写回已整理资料…") { writing = project }
                Text("本地扫描完成、AI 整理完成、资产已确认和镜头已使用分别记录。").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
    private func metric(_ name: String, _ count: Int) -> some View {
        VStack(alignment: .leading) { Text("\(count)").font(.title); Text(name).font(.caption).foregroundStyle(.secondary) }
    }
}

struct ProjectWorkspaceRegistration: View {
    @ObservedObject var service: ProjectAutomationService
    let folders: [String]
    let existing: [ProjectRecord]
    let onClose: () -> Void
    @State private var roots: [URL] = []
    @State private var name = ""
    @State private var existingID: String?
    @State private var automatic = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建项目").font(.title2.bold())
            TextField("项目名称", text: $name)
            Text("一个项目可以链接多个目录，各目录保留原来的文件夹层级。也可以先建项目，稍后添加目录。")
            Menu("从已有资料选择目录（可选）") {
                ForEach(existing) { p in Button(p.name) { if roots.isEmpty { existingID = p.id }; append([URL(fileURLWithPath: p.rootPath)]); if name.isEmpty { name = p.name } } }
                ForEach(folders, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { append([URL(fileURLWithPath: path)]) } }
            }
            Button("添加链接目录…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { append(panel.urls) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(roots, id: \.path) { root in
                        HStack { Label(root.lastPathComponent, systemImage: "folder"); Text(root.path).font(.caption).lineLimit(2); Spacer(); Button("取消") { roots.removeAll { $0 == root }; existingID = nil } }
                    }
                    if roots.isEmpty { Text("尚未链接目录，可稍后添加").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 180)
            if !roots.isEmpty { Toggle("开启此项目自动整理", isOn: $automatic) }
            Text("若开启，软件打开期间会向已配置的 API 发送本项目新增或变化的必要文字，可能产生 API 费用。标准记录跳过 AI；可随时暂停。").font(.caption)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack { Button("取消", action: onClose); Spacer(); Button(roots.isEmpty ? "创建项目" : "创建并接入") {
                do { try service.register(name: name, roots: roots, id: existingID, automatic: automatic); onClose() }
                catch { self.error = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !service.library.canEdit).buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 580)
    }
    private func append(_ urls: [URL]) {
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            if !roots.contains(path) { roots.append(path) }
        }
    }
}
