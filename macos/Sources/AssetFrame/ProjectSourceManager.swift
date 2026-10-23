import SwiftUI
import AppKit

struct ProjectSourceManager: View {
    let projectID: String
    @ObservedObject var service: ProjectAutomationService
    let onClose: () -> Void
    @State private var error: String?
    private var project: CharacterLibraryRegistry.Project? { service.library.registry.projects.first { $0.id == projectID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("项目链接目录").font(.title2.bold()); Spacer(); Button("完成", action: onClose) }
            Text(project?.name ?? "项目").font(.headline)
            Text("可添加多个位置。只建立链接，文件继续保留在原目录；取消链接不删除原文件。").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(project?.sources ?? []) { source in
                        HStack(alignment: .top) {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.headline)
                                Text(source.path).font(.caption).textSelection(.enabled)
                            }
                            Spacer()
                            Button("取消链接") {
                                do { try service.unlinkSource(source.id, projectID: projectID); error = nil }
                                catch { self.error = error.localizedDescription }
                            }.disabled(!service.library.canEdit)
                        }
                        Divider()
                    }
                    if project?.sources.isEmpty != false { Text("尚未链接目录").foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("添加后立即本地识别。若项目原已开启自动 AI，新增范围会先暂停发送，可在概览核对目录后重新开启。").font(.caption).foregroundStyle(.secondary)
            Button("添加链接目录…", systemImage: "folder.badge.plus") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = true; panel.prompt = "链接所选目录"
                if panel.runModal() == .OK {
                    do { try service.linkSources(panel.urls, projectID: projectID); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).disabled(!service.library.canEdit)
        }.padding(24).frame(width: 680, height: 480)
    }
}
