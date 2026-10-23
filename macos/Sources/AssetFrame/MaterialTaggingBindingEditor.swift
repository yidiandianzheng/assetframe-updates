import SwiftUI
import AppKit

struct MaterialTaggingBindingEditor: View {
    let binding: MaterialTaggingState.Binding
    var issue: String? = nil
    var saving = false
    let onSave: (String?) -> Void
    let onCancel: () -> Void
    @State private var excerpt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("图片对应的原文片段").font(.title2)
            Text(binding.documentPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Text(binding.kind).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开原文", systemImage: "doc.text") { NSWorkspace.shared.open(URL(fileURLWithPath: binding.documentPath)) }
            }
            Text("粘贴此图对应的原文片段，可留空。片段必须在当前文档中唯一出现；保存后只提取该片段，并核对整份文档的版本。").font(.callout)
            TextEditor(text: $excerpt).font(.body).border(Color.secondary.opacity(0.35))
                .accessibilityLabel("此图对应的原文片段，可留空")
            HStack {
                Text("\(excerpt.count) / 12000 字").font(.caption).foregroundStyle(excerpt.count > 12000 ? Color.orange : Color.secondary)
                Spacer()
                if !excerpt.isEmpty { Button("清空片段，使用文档自动定位") { excerpt = "" } }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存片段") { onSave(excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt) }
                    .buttonStyle(.borderedProminent).disabled(excerpt.count > 12000)
            }
        }.padding(24).frame(width: 700, height: 570)
            .disabled(saving).interactiveDismissDisabled(saving)
            .task { excerpt = binding.excerpt ?? "" }
    }
}
