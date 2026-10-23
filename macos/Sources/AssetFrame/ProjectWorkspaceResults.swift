import SwiftUI
import AppKit

struct ProjectWorkspaceResults: View {
    let project: CharacterLibraryRegistry.Project
    @ObservedObject var service: ProjectAutomationService
    @ObservedObject var materials: GlobalMaterialStore
    let section: String
    let onVersions: () -> Void
    @State private var association = ""
    @State private var proposedID = ""
    @State private var proposedName = ""
    @State private var proposedKind = "人物"
    @State private var editing: CharacterLibraryStore.Loaded?
    @EnvironmentObject private var editGuard: InspectorEditGuard
    private struct Row: Identifiable {
        var id: String
        var name: String
        var kind: String
        var target: ProjectAutomationState.Target?
        var jobs: [ProjectAutomationState.Job]
    }
    private var root: URL { URL(fileURLWithPath: project.rootPath) }
    private var people: [CharacterLibraryStore.Loaded] { service.library.loaded.filter { $0.entry.projectID == project.id } }
    private var graph: ProjectAssetGraph { service.graphs[project.id] ?? .init(projectID: project.id) }
    private var targets: [ProjectAutomationState.Target] {
        var all = people.map { ProjectAutomationState.Target(id: $0.entry.characterID, kind: "人物", name: $0.profile?.name ?? $0.entry.characterID) }
        all += graph.subjects.map { .init(id: $0.id, kind: $0.kind, name: $0.name) }
        all += service.jobs(project: project.id).compactMap(\.target)
        return Array(Set(all)).sorted { $0.id < $1.id }
    }
    private var rows: [Row] {
        let jobs = service.jobs(project: project.id)
        let result: [Row]
        if section == "待核对" {
            result = jobs.filter { ["待核对", "失败", "待重试"].contains($0.status) }.map {
                Row(id: $0.id, name: $0.target?.name ?? $0.result.flatMap { $0.name.isEmpty ? nil : $0.name } ?? URL(fileURLWithPath: $0.path).lastPathComponent,
                    kind: $0.target?.kind ?? $0.result?.kind ?? "待识别", target: $0.target, jobs: [$0])
            }
        } else {
            result = targets.filter { $0.kind == section }.map { target in
                Row(id: target.id, name: target.name, kind: target.kind, target: target, jobs: jobs.filter { $0.target?.id == target.id })
            }
        }
        let search = service.state.navigation.search
        return result.filter { search.isEmpty || ($0.name + $0.id).localizedCaseInsensitiveContains(search) }
    }
    private var selected: Row? { rows.first { $0.id == service.state.navigation.selectedID } ?? rows.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索资产名称或 ID", text: Binding(get: { service.state.navigation.search }, set: { service.setSearch($0) })).textFieldStyle(.roundedBorder)
                Text("\(rows.count) 项").font(.caption)
                if section != "待核对" { Button("管理造型、版本与镜头", action: onVersions) }
            }.padding(12)
            HSplitView {
                List(selection: Binding(get: { selected?.id }, set: { if let id = $0 { service.select(id) } })) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.name).font(.headline)
                            Text(row.target?.id ?? "身份待核对").font(.caption).foregroundStyle(.secondary)
                            if row.jobs.contains(where: { $0.status == "待核对" }) { Text("有待核对资料").font(.caption).foregroundStyle(.orange) }
                            else if !row.jobs.isEmpty { Text("资料来源 \(row.jobs.count) 份").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5).tag(row.id)
                    }
                }.frame(minWidth: 210, idealWidth: 260, maxWidth: 340)
                if let selected { details(selected) }
                else {
                    ContentUnavailableView(section == "待核对" ? "当前没有待核对事项" : "暂无匹配资产", systemImage: "doc.text.magnifyingglass",
                        description: Text(service.state.navigation.search.isEmpty ? "已识别的标准资料和带明确身份的整理结果会自动显示。身份不明确的资料在待核对中。" : "当前搜索没有匹配项，清空搜索查看全部。"))
                }
            }
        }
        .sheet(item: $editing) { row in CharacterProfileEditor(library: service.library, materials: materials, loaded: row, onClose: { editing = nil; service.refresh() }).environmentObject(editGuard) }
    }
    private func details(_ row: Row) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(row.name).font(.title2.bold())
                if let person = people.first(where: { $0.entry.characterID == row.target?.id }), let profile = person.profile {
                    GroupBox("当前人物档案 · 原 MD") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(profile.fields.keys.sorted(), id: \.self) { key in
                                if let text = profile.fields[key]?.text, !text.isEmpty { Text(key).font(.headline); Text(text).textSelection(.enabled) }
                            }
                            ForEach(profile.assets) { asset in
                                HStack {
                                    Text(asset.role + " · " + asset.status)
                                    if let m = materials.materials.first(where: { $0.id == asset.materialID }), let location = m.fileLocation {
                                        Button(m.name) { NSWorkspace.shared.open(location.url) }
                                    }
                                }
                            }
                            HStack { Button("打开原文") { NSWorkspace.shared.open(URL(fileURLWithPath: person.entry.sourcePath)) }; Button("编辑档案…") { editing = person } }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if let subject = graph.subjects.first(where: { $0.id == row.target?.id }) {
                    Text(subject.description).textSelection(.enabled)
                    if !subject.sourcePath.isEmpty { Button("打开主体原文") { NSWorkspace.shared.open(CharacterProjectModules.resolve(subject.sourcePath, root: root)) } }
                }
                ForEach(row.jobs) { job in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("AI 整理 · " + job.status).font(.headline); Spacer(); Button("打开来源") { NSWorkspace.shared.open(root.appendingPathComponent(job.path)) } }
                            Text(job.path).font(.caption).textSelection(.enabled)
                            if !job.issue.isEmpty { Text(job.issue).foregroundStyle(.orange) }
                            if let result = job.result {
                                ForEach(Array(result.fields.enumerated()), id: \.offset) { _, field in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(field.name).font(.headline); Spacer(); Button("复制") { copy(field.value) } }
                                        Text(field.value).textSelection(.enabled)
                                        DisclosureGroup("原文依据") { Text(field.evidence).font(.caption).textSelection(.enabled) }
                                    }
                                }
                                if result.fields.isEmpty { Text("未提取到可展示字段；原资料保留。").foregroundStyle(.secondary) }
                            }
                            if section == "待核对", job.result != nil { review(job) }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                let links = materials.links.filter { $0.projectID == project.id && $0.subjectID == row.target?.id }
                if !links.isEmpty {
                    Text("已用镜头").font(.headline)
                    ForEach(links) { link in Text([link.episode, link.scene, link.shot].compactMap { $0 }.joined(separator: " / ") + " · " + link.materialID) }
                }
                if row.jobs.isEmpty { Text("标准记录直接读取，无需 AI 整理。").font(.caption).foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 400)
    }
    @ViewBuilder private func review(_ job: ProjectAutomationState.Job) -> some View {
        if let target = job.target {
            Button("已核对，采用此份整理资料") { service.approve(job, target: target) }
            Text("仅记录此份资料已核对；不覆盖现有正文、不确认图片用途。").font(.caption)
        } else {
            Picker("关联已有主体", selection: $association) {
                Text("选择一次，后续复用").tag("")
                ForEach(targets) { Text($0.kind + " · " + $0.name + " · " + $0.id).tag($0.id) }
            }
            Button("保存关联并继续整理") { if let target = targets.first(where: { $0.id == association }) { service.approve(job, target: target) } }.disabled(association.isEmpty)
            DisclosureGroup("登记新主体身份") {
                TextField("稳定 ID", text: $proposedID)
                TextField("主体名称", text: $proposedName)
                Picker("类型", selection: $proposedKind) { ForEach(ProjectAssetGraph.kinds, id: \.self) { Text($0).tag($0) } }
                Button("保存身份关联") { service.approve(job, target: .init(id: proposedID.trimmingCharacters(in: .whitespaces), kind: proposedKind, name: proposedName.trimmingCharacters(in: .whitespaces))) }
                    .disabled(proposedID.trimmingCharacters(in: .whitespaces).isEmpty || proposedName.trimmingCharacters(in: .whitespaces).isEmpty || targets.contains { $0.id == proposedID })
            }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
