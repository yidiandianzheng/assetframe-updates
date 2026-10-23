import SwiftUI

struct LibraryManagerView: View {
    @ObservedObject var session: LibrarySession
    @EnvironmentObject private var editGuard: InspectorEditGuard
    let onClose: () -> Void
    let onProject: (ProjectManagementRoute) -> Void
    @State private var search = ""
    @State private var availability: [String: String] = [:]
    @State private var pendingRemoval: LibraryLocation?

    private var locations: [LibraryLocation] {
        session.registry.locations.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("资源库存储管理").font(.title2)
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            if session.product == .story {
            GroupBox("要建立一部作品？") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("新建项目后，可以链接多个剧本、图片和声音目录。")
                        Text("资源库存放项目索引和素材记录；一个资源库可以管理多个项目。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("新建项目…", systemImage: "plus") { editGuard.request { onProject(.create) } }
                        .buttonStyle(.borderedProminent)
                    Button("管理项目…") { editGuard.request { onProject(.manage) } }
                }.padding(6)
            }.disabled(session.projectWorkspace == nil || session.busy)
            }
            HStack {
                Button("新建资源库…", systemImage: "externaldrive.badge.plus") { editGuard.request { session.chooseCreate() } }
                Button("打开已有资源库…", systemImage: "folder") { editGuard.request { session.chooseOpen() } }
                Spacer()
            }.disabled(session.busy)
            Text("以下是资源库存储位置。移除登记会保留磁盘上的资源库与原始素材。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("搜索名称或路径…", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(locations) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "externaldrive").padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.name).font(.headline)
                                    if item.id == session.descriptor?.id {
                                        Text("当前").font(.caption).foregroundStyle(.blue)
                                    }
                                }
                                Text(item.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(item.path)
                                if session.product == .story && item.id == session.descriptor?.id {
                                    Text("当前库 · \(session.projectWorkspace?.library.registry.projects.count ?? 0) 个项目").font(.caption).foregroundStyle(.secondary)
                                }
                                let status = availability[item.id] ?? "正在检查…"
                                Text(status).font(.caption)
                                    .foregroundStyle(status == "可用" ? Color.secondary : Color.orange)
                            }
                            Spacer(minLength: 8)
                            if item.id != session.descriptor?.id {
                                Button("打开") { editGuard.request { Task { await session.open(URL(fileURLWithPath: item.path)) } } }
                                    .disabled(session.busy || availability[item.id] != "可用")
                            }
                            Button("移除登记…", role: .destructive) { pendingRemoval = item }
                                .accessibilityLabel("移除资源库 \(item.name)")
                                .disabled(session.busy)
                        }.padding(.vertical, 12)
                        Divider()
                    }
                    if locations.isEmpty {
                        Text(session.registry.locations.isEmpty ? "没有已登记的资源库" : "没有匹配的资源库")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }
            }.frame(minHeight: 230, maxHeight: 330)
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("已登记 \(session.registry.locations.count) 个资源库").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新检查") { Task { await checkAvailability() } }.disabled(session.busy)
            }
        }.padding(24).frame(width: 740)
        .task(id: session.registry.locations) { await checkAvailability() }
        .alert("移除“\(pendingRemoval?.name ?? "资源库")”？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除登记", role: .destructive) {
                guard let item = pendingRemoval else { return }
                pendingRemoval = nil
                editGuard.request { Task { await session.removeRegisteredLibrary(item.id) } }
            }
        } message: {
            Text("只从软件列表移除，不删除任何资源库文件或素材。\(pendingRemoval?.id == session.descriptor?.id ? "当前库将关闭，并切换到其他可用资源库。" : "当前打开的资源库不受影响。")之后可通过“打开其他资源库”重新添加。")
        }
    }

    private func checkAvailability() async {
        let entries = session.registry.locations
        let checked = await Task.detached(priority: .utility) {
            var result: [String: String] = [:]
            for item in entries {
                let url = URL(fileURLWithPath: item.path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    result[item.id] = "路径不可用：可能已移动、删除或磁盘未连接"
                    continue
                }
                do {
                    let descriptor = try LibraryDescriptor.read(url)
                    result[item.id] = descriptor.id == item.id ? "可用" : "资源库标识已变化，请重新打开"
                } catch { result[item.id] = "无法读取：\(error.localizedDescription)" }
            }
            return result
        }.value
        guard !Task.isCancelled, entries == session.registry.locations else { return }
        availability = checked
    }
}
