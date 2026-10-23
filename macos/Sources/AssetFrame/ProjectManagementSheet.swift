import SwiftUI

struct ProjectManagementSheet: View {
    @ObservedObject var service: ProjectAutomationService
    @ObservedObject var library: CharacterLibraryStore
    @ObservedObject var materials: GlobalMaterialStore
    let libraryName: String
    let initial: ProjectManagementRoute
    let onClose: () -> Void
    private enum Screen { case list, create, sources(String) }
    @State private var screen = Screen.list
    @State private var search = ""
    private var projects: [CharacterLibraryRegistry.Project] {
        library.registry.projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch screen {
            case .list:
                projectList
            case .create:
                Button("返回项目列表", systemImage: "chevron.left") { screen = .list }.padding([.top, .horizontal], 20)
                ProjectWorkspaceRegistration(service: service, folders: materials.organization.folders.map(\.rootPath),
                    existing: materials.organization.projects, onClose: onClose)
            case .sources(let id):
                Button("返回项目列表", systemImage: "chevron.left") { screen = .list }.padding([.top, .horizontal], 20)
                ProjectSourceManager(projectID: id, service: service, onClose: { screen = .list })
            }
        }
        .onAppear { screen = initial == .create ? .create : .list }
    }
    private var projectList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("项目管理").font(.title2.bold())
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("当前资源库：" + libraryName).font(.caption).foregroundStyle(.secondary)
            Text("每部作品建立一个项目。项目内链接多个原始目录，再按分集、人物和素材统一浏览。")
                .foregroundStyle(.secondary)
            HStack {
                TextField("搜索项目…", text: $search).textFieldStyle(.roundedBorder)
                Button("新建项目…", systemImage: "plus") { screen = .create }
                    .buttonStyle(.borderedProminent).disabled(!library.canEdit)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(project.name, systemImage: "folder").font(.headline)
                                if service.state.navigation.projectID == project.id { Text("当前项目").font(.caption).foregroundStyle(.tint) }
                                Spacer()
                                Button("打开项目") { service.navigate(project: project.id, section: "概览"); onClose() }
                                Button("管理链接目录…") { screen = .sources(project.id) }
                            }
                            Text("\(project.sources.count) 个链接目录 · " + (service.state.permissions[project.id]?.enabled == true ? "已开启自动整理" : "本地读取"))
                                .font(.caption).foregroundStyle(.secondary)
                            if project.sources.isEmpty { Text("尚未链接资料，可以先建立项目再添加目录。").font(.caption).foregroundStyle(.secondary) }
                            ForEach(project.sources.prefix(3)) { source in
                                Label(source.path, systemImage: "link").font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(source.path)
                            }
                            if project.sources.count > 3 { Text("另有 \(project.sources.count - 3) 个目录，可在管理中查看。").font(.caption).foregroundStyle(.secondary) }
                        }.padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if projects.isEmpty {
                        ContentUnavailableView(library.registry.projects.isEmpty ? "还没有项目" : "没有匹配项目", systemImage: "folder",
                            description: Text("点击“新建项目”，填写作品名称；资料目录可以稍后添加。"))
                    }
                }
            }
            Text("\(library.registry.projects.count) 个项目 · 资料保留在原目录").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 510)
    }
}
