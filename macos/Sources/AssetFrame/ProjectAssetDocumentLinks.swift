import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Links stay in library metadata; choosing a document never rewrites project Markdown.
struct ProjectAssetDocumentLinks: View {
    let title: String
    let paths: [String]
    let root: URL
    var associate: (() -> Void)? = nil
    @State private var failed = false
    var body: some View {
        Menu {
            ForEach(Array(Set(paths)).sorted(), id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) {
                    failed = !NSWorkspace.shared.open(CharacterProjectModules.resolve(path, root: root))
                }.help(CharacterProjectModules.resolve(path, root: root).path)
            }
            if paths.isEmpty { Text("尚未关联 MD") }
            if let associate { Divider(); Button("关联\(title) MD…", action: associate) }
        } label: { Label(title + " MD" + (paths.isEmpty ? " · 待关联" : " · \(Set(paths).count)"), systemImage: "doc.text") }
        .alert("无法打开 MD", isPresented: $failed) { Button("好", role: .cancel) {} } message: { Text("请检查原文件是否仍在，以及磁盘是否在线。") }
    }
    @MainActor static func choose(kind: String, projectID: String, target: String, service: ProjectAutomationService) {
        let panel = NSOpenPanel()
        panel.title = "关联\(kind) MD"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { service.linkAssetDocument(url, projectID: projectID, target: target, kind: kind) }
    }
}
