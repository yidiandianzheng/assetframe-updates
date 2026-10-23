import SwiftUI
import AppKit

struct CharacterConfirmationView: View {
    let project: CharacterLibraryRegistry.Project
    let loaded: CharacterLibraryStore.Loaded
    @ObservedObject var library: CharacterLibraryStore
    @ObservedObject var materials: GlobalMaterialStore
    let onClose: () -> Void
    @EnvironmentObject private var editGuard: InspectorEditGuard
    @State private var materialID = ""
    @State private var query = ""
    @State private var variant = "基础"
    @State private var role = "主图"
    @State private var stage = ""
    @State private var evidence = ""
    @State private var platform = ""
    @State private var model = ""
    @State private var originalPrompt = ""
    @State private var normalized: [String: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var prepared: CharacterProjectModules.Receipt?
    @State private var preview = ""
    @State private var index: CharacterProjectModules.Index?
    @State private var indexHash: String?
    private var root: URL { URL(fileURLWithPath: project.rootPath) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("记录资产确认 · \(loaded.profile?.name ?? loaded.entry.characterID)").font(.title2.bold())
            Text("将具体文件、指纹、用途、原始提示词与人设路径串联。此操作只确认所选视觉或声线，不确认全部人设，也不替换其他默认资产。").font(.caption)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if prepared != nil {
                ScrollView { Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("返回编辑") { prepared = nil }
                    Button("复制记录") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preview, forType: .string) }
                    Spacer()
                    Button("确认该资产并保存记录") { save() }.disabled(busy || !library.canEdit || !materials.canWrite)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("查找已导入素材", text: $query)
                        Picker("具体资产", selection: $materialID) {
                            Text("选择一份实际素材").tag("")
                            ForEach(materials.materials.filter { $0.deletedAt == nil && ($0.id == materialID || query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }.prefix(100)) { Text($0.name).tag($0.id) }
                        }
                        if let item = materials.materials.first(where: { $0.id == materialID }) {
                            Text(item.sourcePath ?? "缺少本地文件").font(.caption).textSelection(.enabled)
                            Button("预览／试听") { MaterialQuickLookController.shared.show(item) }.disabled(item.sourceMissing)
                        }
                        HStack {
                            TextField("造型版本", text: $variant)
                            Picker("资产用途", selection: $role) { ForEach(CharacterProfile.Asset.roles, id: \.self) { Text($0).tag($0) } }
                        }
                        TextField("适用阶段／集数", text: $stage)
                        TextField("确认依据（例如本次已查看并确认；或原确认记录位置）", text: $evidence)
                        HStack { TextField("生成平台（未知留空）", text: $platform); TextField("实际模型（未知留空）", text: $model) }
                        Text("实际生成原始提示词").font(.headline)
                        Text("从素材生成信息预填；请核对。未知可留空，记录为待补充。下方标准化模板独立保存，不能替代实际使用原文。").font(.caption)
                        TextEditor(text: $originalPrompt).frame(height: 130).border(Color.secondary.opacity(0.2)).accessibilityLabel("原始提示词")
                        DisclosureGroup("标准化提示词模板（可复用候选）") {
                            ForEach(CharacterProfile.groups[2].1, id: \.self) { key in
                                Text(key).font(.headline)
                                TextEditor(text: Binding(get: { normalized[key] ?? "" }, set: { normalized[key] = $0 })).frame(height: 70).border(Color.secondary.opacity(0.2)).accessibilityLabel("模板 " + key)
                            }
                        }
                    }.textFieldStyle(.roundedBorder)
                }
                HStack { Button("取消") { onClose() }; Spacer(); Button("预览确认记录…") { prepare() }.disabled(materialID.isEmpty || evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy) }
            }
            if busy { ProgressView("核对文件并保存…") }
        }.padding(20).frame(minWidth: 780, idealWidth: 900, minHeight: 650, idealHeight: 760)
        .disabled(busy)
        .interactiveDismissDisabled()
        .onAppear {
            for key in CharacterProfile.groups[2].1 { normalized[key] = loaded.profile?.fields[key]?.text ?? "" }
            editGuard.dirty = true; editGuard.save = nil; editGuard.discard = { onClose() }
        }
        .onDisappear { editGuard.dirty = false; editGuard.save = nil; editGuard.discard = nil }
        .onChange(of: materialID) { _, id in
            if let item = materials.materials.first(where: { $0.id == id }) {
                originalPrompt = item.production?.prompt ?? ""; platform = item.production?.platform ?? ""; model = item.production?.model ?? ""
                if let asset = loaded.profile?.assets.first(where: { $0.materialID == id }) { variant = asset.variant; role = asset.role; stage = asset.stage }
            }
        }
    }
    private func prepare() {
        guard let item = materials.materials.first(where: { $0.id == materialID }), let url = item.fileLocation?.url, !item.sourceMissing else { error = "素材文件缺失，请先重新定位或导入。"; return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let hash = try await Task.detached { try CharacterProjectModules.fileHash(url) }.value
                let receipt = CharacterProjectModules.Receipt(projectID: project.id, characterID: loaded.entry.characterID, assetPath: CharacterProjectModules.relative(url, root: root), sha256: hash, materialID: item.id, variant: variant, role: role, stage: stage, confirmationEvidence: evidence, platform: platform, model: model, originalPrompt: originalPrompt, normalizedPrompt: normalized, profilePath: CharacterProjectModules.relative(URL(fileURLWithPath: loaded.entry.sourcePath), root: root), sourcePaths: loaded.profile?.sources.map { CharacterProjectModules.relative(CharacterProjectModules.resolve($0, root: URL(fileURLWithPath: loaded.entry.sourcePath).deletingLastPathComponent()), root: root) } ?? [])
                try receipt.validate()
                let snapshot = try CharacterProjectModules.readIndex(root: root, projectID: project.id)
                index = snapshot.0; indexHash = snapshot.1
                preview = try CharacterProjectModules.encode(receipt, marker: "assetframe-confirmation", title: "资产确认与生成记录")
                prepared = receipt
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        guard let receipt = prepared, let index else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                guard materials.canWrite,
                      let item = materials.materials.first(where: { $0.id == receipt.materialID && $0.deletedAt == nil }),
                      item.fileLocation?.url.resolvingSymlinksInPath().path == CharacterProjectModules.resolve(receipt.assetPath, root: root).resolvingSymlinksInPath().path else {
                    throw CharacterLibraryError.invalid("素材记录已改变，请返回重新选择")
                }
                _ = try await CharacterModuleWorkflow.confirm(receipt: receipt, root: root, loaded: loaded, library: library, index: index, indexHash: indexHash)
                library.notice = "已保存确认记录、生成原文与模块索引；其他默认资产保持原状态。"; onClose()
            } catch { self.error = error.localizedDescription }
        }
    }
}
