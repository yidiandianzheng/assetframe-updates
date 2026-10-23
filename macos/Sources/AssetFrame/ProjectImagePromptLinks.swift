import SwiftUI
import AppKit

struct ProjectImagePromptLinks: View {
    let media: ProjectWorkbenchIndex.Media?
    let path: String
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    @State private var showing = false
    private var paths: [String] {
        Array(Set((media?.promptSources ?? []) + service.assetDocumentPaths(projectID: project.id, target: path, kind: "生成提示词"))).sorted()
    }
    var body: some View {
        Button("生成提示词", systemImage: "text.quote") { showing = true }
            .popover(isPresented: $showing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这张图的生成提示词").font(.headline)
                        Text("原始生成提示词").font(.subheadline.bold())
                        if let prompt = media?.prompt, !prompt.isEmpty {
                            Text(prompt).textSelection(.enabled)
                            Button("复制原始提示词") { copy(prompt) }
                        } else { Text("尚未记录生成原文").foregroundStyle(.secondary) }
                        if let reuse = media?.reuse, !reuse.isEmpty {
                            Divider()
                            Text("标准化复用模板").font(.subheadline.bold())
                            Text(reuse).textSelection(.enabled)
                            Button("复制复用模板") { copy(reuse) }
                        }
                        Divider()
                        ProjectAssetDocumentLinks(title: "生成提示词", paths: paths, root: URL(fileURLWithPath: project.rootPath))
                        Text("关联文档供查阅；其内容不自动视为这张图实际使用的生成原文。").font(.caption).foregroundStyle(.secondary)
                        Button("关联生成提示词 MD…") {
                            showing = false
                            ProjectAssetDocumentLinks.choose(kind: "生成提示词", projectID: project.id, target: path, service: service)
                        }
                    }.padding(16).frame(width: 350, alignment: .leading)
                }.frame(maxHeight: 520)
            }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
