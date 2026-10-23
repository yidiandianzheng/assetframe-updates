import SwiftUI
import AppKit

struct CharacterProjectEditor: View {
    let existing: [ProjectRecord]
    let onSave: (String, URL, String?) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var root: URL?
    @State private var existingID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登记人物所属项目").font(.title2)
            Text("链接整个项目文件夹。登记后可点击“识别项目资料”扫描 MD 并整理关联。").font(.caption)
            if !existing.isEmpty {
                Menu("使用已有项目") {
                    ForEach(existing) { project in
                        Button(project.name) { name = project.name; root = URL(fileURLWithPath: project.rootPath); existingID = project.id }
                    }
                }
            }
            TextField("项目名称", text: $name).textFieldStyle(.roundedBorder)
            Button("选择项目目录…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { root = url; existingID = nil; if name.isEmpty { name = url.lastPathComponent } }
            }
            Text(root?.path ?? "尚未选择").font(.caption).textSelection(.enabled)
            HStack { Button("取消", action: onCancel); Spacer(); Button("登记") { if let root { onSave(name, root, existingID) } }.disabled(root == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 520)
    }
}
