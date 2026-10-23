import SwiftUI

/// A prepared batch remains visible if one file fails. Successful entries are not retried.
struct ProjectWorkspaceWriteback: View {
    typealias Draft = ProjectAutomationState.WritebackDraft
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    let onClose: () -> Void
    @State private var drafts: [Draft] = []
    @State private var saved: Set<String> = []
    @State private var issues: [String] = []
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("集中预览写回").font(.title2.bold())
            Text("只追加到有明确单一主体归属的原资料。原文保留，每份写入前复核来源并保存备份。AI 整理字段保持候选，不改变已确认资产用途。")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(drafts) { draft in
                        DisclosureGroup((saved.contains(draft.id) ? "已保存 · " : "待保存 · ") + draft.path) { Text(draft.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                    ForEach(Array(issues.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.orange) }
                    if drafts.isEmpty { Text("没有可直接写回的单一主体资料；共享资料或冲突保留在工作台，需先核对来源。") }
                }
            }
            HStack { Button("关闭", action: onClose).disabled(busy); Spacer(); Button("保存未完成项") { save() }.disabled(busy || drafts.allSatisfy { saved.contains($0.id) }) }
        }.padding(24).frame(width: 780, height: 600).task { prepare() }
    }
    private func prepare() {
        if let pending = service.state.pendingWritebacks?[project.id], !pending.isEmpty {
            drafts = pending
            issues.append("已恢复上次未完成的写回预览；来源变化时仍会拒绝覆盖。")
            return
        }
        let jobs = service.jobs(project: project.id).filter { ["整理完成", "已采用"].contains($0.status) && $0.result != nil && $0.target != nil }
        let groups = Dictionary(grouping: jobs, by: \.path)
        for (path, items) in groups.sorted(by: { $0.key < $1.key }) {
            guard Set(items.compactMap { $0.target?.id }).count == 1, let job = items.first, let target = job.target else { continue }
            let root = URL(fileURLWithPath: project.rootPath)
            let url = CharacterProjectModules.resolve(path, root: root)
            do {
                let (original, hash) = try CharacterMarkdown.read(url)
                guard hash == job.fingerprint else { throw CharacterLibraryError.conflict }
                if target.kind == "人物" {
                    // Do not make a second persona record in an asset card or a shared index.
                    guard original.contains("document_type: 人物角色卡") || original.contains(CharacterMarkdown.begin) else { continue }
                    var profile = (try? CharacterMarkdown.decode(original, projectID: project.id, characterID: target.id)) ?? CharacterProfile(projectID: project.id, characterID: target.id)
                    if profile.fields["姓名"]?.text.isEmpty != false { profile.fields["姓名"] = .init(text: target.name, review: .candidate, evidence: "现有角色身份；软件未重新确认") }
                    for item in items {
                        for field in item.result?.fields ?? [] where CharacterProfile.fieldNames.contains(field.name) {
                            if profile.fields[field.name]?.text.isEmpty != false {
                                profile.fields[field.name] = .init(text: field.value, review: .candidate, evidence: path + "\n" + field.evidence)
                            }
                        }
                    }
                    profile.sources = Array(Set(profile.sources + [path])).sorted()
                    drafts.append(.init(id: path, path: url.path, expected: hash, text: try CharacterMarkdown.render(profile, replacing: original)))
                } else {
                    // Other subjects retain all real prompt text and evidence in the existing document.
                    let marker = "assetframe-organized-evidence"
                    let payload = try CharacterProjectModules.encode(items.compactMap(\.result), marker: marker, title: "资料整理候选（不代表资产确认）")
                    let start = "<!-- \(marker):v1 -->", end = "<!-- /\(marker) -->"
                    var text = original
                    if let a = text.range(of: start), let b = text.range(of: end), a.lowerBound < b.upperBound {
                        text.replaceSubrange(a.lowerBound..<b.upperBound, with: payload)
                    } else { text += "\n\n" + payload }
                    drafts.append(.init(id: path, path: url.path, expected: hash, text: text))
                }
            } catch { issues.append(path + "：" + error.localizedDescription) }
        }
    }
    private func save() {
        guard service.preserveWriteback(drafts.filter { !saved.contains($0.id) }, project: project.id) else {
            issues.append("无法持久保存预览，尚未写入项目文件。请恢复资源库连接后再试。")
            return
        }
        busy = true
        for draft in drafts where !saved.contains(draft.id) {
            do { _ = try CharacterMarkdown.save(draft.text, to: URL(fileURLWithPath: draft.path), expected: draft.expected); saved.insert(draft.id) }
            catch { issues.append(draft.path + "：" + error.localizedDescription + "；预览草稿保留") }
        }
        _ = service.preserveWriteback(drafts.filter { !saved.contains($0.id) }, project: project.id)
        busy = false; service.refresh()
    }
}
