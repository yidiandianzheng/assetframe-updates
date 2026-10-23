import SwiftUI

struct MaterialUsageDraft: Identifiable {
    let id = UUID()
    let materialID: String
    var inPoint: Double? = nil
    var outPoint: Double? = nil
    var subjectID: String? = nil
    var variantID: String? = nil
    var boundFingerprint: String? = nil
    var originalPrompt: String? = nil
    var reuseTemplate: String? = nil
}

struct MaterialUsageEditor: View {
    @ObservedObject var store: GlobalMaterialStore
    let project: ProjectRecord
    let draft: MaterialUsageDraft
    let onClose: () -> Void
    @State private var episode = ""
    @State private var scene = ""
    @State private var shot = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    private var material: MaterialRecord? { store.materials.first { $0.id == draft.materialID && $0.deletedAt == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选用此版本并加入交付").font(.title2)
            Text(material?.name ?? "素材已不可用").font(.headline)
            Text("固定引用当前素材 ID；以后关联或导入新版本，不会替换本次选用。").font(.caption).foregroundStyle(.secondary)
            TextField("集数（可选）", text: $episode)
            TextField("场次（可选）", text: $scene)
            TextField("镜头（可选）", text: $shot)
            TextField("用途备注（可选）", text: $note)
            if let start = draft.inPoint, let end = draft.outPoint {
                Text("区间：\(start.formatted()) — \(end.formatted()) 秒")
                Text("导出完整原文件，区间写入清单，不裁切媒体。").font(.caption)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "正在保存…" : "确认选用") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(material == nil || !store.canWrite)
            }
        }.padding(24).frame(width: 480).textFieldStyle(.roundedBorder)
            .disabled(saving).interactiveDismissDisabled()
    }

    private func save() async {
        guard !saving else { return }
        saving = true; defer { saving = false }
        func optional(_ value: String) -> String? {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        let link = ProjectMaterialLink(id: draft.id.uuidString, projectID: project.id, materialID: draft.materialID,
            use: .working, episode: optional(episode), scene: optional(scene), shot: optional(shot), selection: "选用",
            inPoint: draft.inPoint, outPoint: draft.outPoint, createdAt: .now, note: note, subjectID: draft.subjectID, variantID: draft.variantID, boundFingerprint: draft.boundFingerprint, originalPrompt: draft.originalPrompt, reuseTemplate: draft.reuseTemplate)
        do {
            try await store.commitUsage(link)
            store.toast = "已固定选用此版本，可在导出中交付"
            onClose()
        } catch { self.error = error.localizedDescription }
    }
}
