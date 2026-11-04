import SwiftUI
import AppKit

/// Project selections are metadata edits in the current library, never changes to source Markdown.
struct ProjectClassificationBar: View {
    @ObservedObject var store: GlobalMaterialStore
    @Binding var profileID: String?
    @Binding var globalExpanded: Bool
    let counts: [String: [String: Int]]
    let resultCount: Int
    let onManage: () -> Void
    @State private var issue: String?
    private var profiles: [ProjectClassificationProfile] { store.tagging.projectClassifications ?? [] }
    private var profile: ProjectClassificationProfile? { profiles.first { $0.id == profileID } }
    private var expanded: Bool { profile?.expanded ?? globalExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if profile != nil { update { $0.expanded.toggle() } } else { globalExpanded.toggle() }
                } label: {
                    Label("项目分类", systemImage: expanded ? "chevron.down" : "chevron.right").font(.callout.weight(.medium))
                }.buttonStyle(.plain)
                Menu {
                    Button("全部素材") { profileID = nil }
                    ForEach(profiles) { p in Button(p.name) { profileID = p.id } }
                } label: {
                    Label(profile?.name ?? "全部素材", systemImage: "folder").lineLimit(1)
                }.frame(maxWidth: 200, alignment: .leading).help("切换项目，同时恢复该项目上次的分类选择")
                Spacer(minLength: 4)
                Text("结果 \(resultCount) 项").font(.caption).foregroundStyle(.secondary)
                Button("管理索引", systemImage: "list.bullet.rectangle", action: onManage).buttonStyle(.borderless)
            }
            if let profile {
                if let warning = profile.issue { Text(warning).font(.caption).foregroundStyle(.orange) }
                if expanded {
                    if profile.dimensions.isEmpty { Text("尚无可筛选分类，请在管理索引中选择、预览并采用索引。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(profile.orderedDimensions.prefix(3))) { dimension in
                        HStack(alignment: .center, spacing: 8) {
                            Text(dimension.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 64, alignment: .leading).help(dimension.name)
                            ViewThatFits(in: .horizontal) {
                                optionRow(dimension, profile: profile, limit: 6)
                                optionRow(dimension, profile: profile, limit: 5)
                                optionRow(dimension, profile: profile, limit: 4)
                                optionRow(dimension, profile: profile, limit: 3)
                                optionRow(dimension, profile: profile, limit: 2)
                                optionRow(dimension, profile: profile, limit: 1)
                                optionRow(dimension, profile: profile, limit: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if profile.orderedDimensions.count > 3 {
                        Menu("其他分类", systemImage: "line.3.horizontal.decrease") {
                            ForEach(Array(profile.orderedDimensions.dropFirst(3))) { dimension in
                                Menu(dimension.name) { menuOptions(dimension, profile: profile) }
                            }
                        }.fixedSize().font(.caption)
                    }
                }
                if !profile.selected.values.allSatisfy(\.isEmpty) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(profile.selected.keys.sorted(), id: \.self) { dimID in
                                ForEach(Array(profile.selected[dimID] ?? []).sorted(), id: \.self) { optID in
                                    let dim = profile.dimensions.first { $0.id == dimID }
                                    let opt = dim?.options.first { $0.id == optID }
                                    Button { toggle(optionID: optID, dimensionID: dimID) } label: {
                                        Label((dim?.name ?? "失效维度") + "：" + (opt?.name ?? "失效选项"), systemImage: "xmark.circle.fill")
                                            .lineLimit(1).font(.caption)
                                    }.buttonStyle(.bordered).help("移除此条件；失效条件不会自动放宽筛选")
                                }
                            }
                            Button("清除分类") { update { $0.selected = [:] } }.font(.caption)
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func optionRow(_ dimension: ProjectClassificationDimension, profile: ProjectClassificationProfile, limit: Int) -> some View {
        HStack(spacing: 6) {
            pill("全部", selected: (profile.selected[dimension.id] ?? []).isEmpty) { update { $0.selected.removeValue(forKey: dimension.id) } }
            ForEach(Array(dimension.orderedOptions.prefix(limit))) { option in
                let count = (counts[dimension.id]?[option.id] ?? 0)
                pill(option.name + " \(count)", selected: profile.selected[dimension.id]?.contains(option.id) == true) {
                    toggle(optionID: option.id, dimensionID: dimension.id)
                }.help(option.name + (option.unavailable ? "（索引中已移除）" : "") + " · \(count) 项")
            }
            if dimension.options.count > limit {
                Menu("更多") { menuOptions(dimension, profile: profile, dropping: limit) }.font(.caption).fixedSize()
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption).lineLimit(1).frame(maxWidth: 160).padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private func menuOptions(_ dimension: ProjectClassificationDimension, profile: ProjectClassificationProfile, dropping: Int = 0) -> some View {
        Button("全部") { update { $0.selected.removeValue(forKey: dimension.id) } }
        ForEach(Array(dimension.orderedOptions.dropFirst(dropping))) { option in
            Toggle(option.name + " \((counts[dimension.id]?[option.id] ?? 0))" + (option.unavailable ? " · 已移除" : ""), isOn: Binding(
                get: { self.profile?.selected[dimension.id]?.contains(option.id) == true },
                set: { _ in toggle(optionID: option.id, dimensionID: dimension.id) }))
        }
    }
    private func toggle(optionID: String, dimensionID: String) {
        update { p in
            var values = p.selected[dimensionID] ?? []
            if values.contains(optionID) { values.remove(optionID) } else { values.insert(optionID) }
            if values.isEmpty { p.selected.removeValue(forKey: dimensionID) } else { p.selected[dimensionID] = values }
        }
    }
    private func update(_ action: @escaping @MainActor (inout ProjectClassificationProfile) -> Void) {
        guard let id = profile?.id else { return }
        Task {
            do {
                try await store.changeTagging { state, _ in
                    guard var profiles = state.projectClassifications, let i = profiles.firstIndex(where: { $0.id == id }) else { throw MaterialDatabase.error("项目配置已变化，请重新选择") }
                    action(&profiles[i]); state.projectClassifications = profiles
                }
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }
}

struct ProjectClassificationManager: View {
    @ObservedObject var store: GlobalMaterialStore
    @Binding var activeProfileID: String?
    let onClose: () -> Void
    var registeredProjects: [CharacterLibraryRegistry.Project] = []
    var linkedFolders: [LocalFolderSource] = []
    @State private var editing: ProjectClassificationProfile?
    @State private var original: ProjectClassificationProfile?
    @State private var candidates: [String] = []
    @State private var selectedPaths: Set<String> = []
    @State private var previewSources: [ProjectClassificationSource] = []
    @State private var hasPreview = false
    @State private var parsedNewSources = false
    @State private var busy = false
    @State private var issue: String?
    @State private var warnings: [String] = []
    @State private var difference = ""
    @State private var previewCounts: [String: [String: Int]] = [:]
    private var profiles: [ProjectClassificationProfile] { store.tagging.projectClassifications ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("管理项目索引").font(.title2.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("完成", action: onClose).keyboardShortcut(.cancelAction).disabled(busy)
            }
            Text("读取已有索引，预览和校正后采用。原索引、原素材及已有素材分类保持原样。").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("链接项目目录…", systemImage: "folder.badge.plus", action: addProject)
                    if !registeredProjects.isEmpty || !linkedFolders.isEmpty {
                        Menu("从已有项目或文件夹选择") {
                            ForEach(registeredProjects) { project in
                                Button(project.name) { begin(name: project.name, roots: project.sources.map(\.path), id: project.id) }
                            }
                            if !registeredProjects.isEmpty && !linkedFolders.isEmpty { Divider() }
                            ForEach(linkedFolders) { folder in
                                Button(folder.name) { begin(name: folder.name, roots: [folder.rootPath], id: "folder:" + folder.id) }
                            }
                        }.font(.caption)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(profiles) { profile in
                                Button { load(profile) } label: {
                                    Text(profile.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                        .background(editing?.id == profile.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(width: 170)
                Divider()
                if let profile = editing { editor(profile) }
                else { ContentUnavailableView("选择项目目录", systemImage: "folder", description: Text("链接目录后，在右侧选择它自己的索引文件。")) }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("只使用本机解析；不会自动导入索引引用的文件。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("采用并保存", action: adopt).buttonStyle(.borderedProminent).disabled(!hasPreview || busy || editing == nil)
            }
        }.padding(20).frame(minWidth: 840, idealWidth: 950, maxWidth: 1100, minHeight: 600, idealHeight: 720)
            .disabled(busy)
            .task(id: editing?.hashValue) {
                guard var snapshot = editing else { return }
                snapshot.selected = [:]
                let materials = store.materials, identity = editing?.hashValue
                let prepared = snapshot
                let worker = Task.detached(priority: .utility) {
                    prepared.evaluation(materials: materials).counts
                }
                let values = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                if !Task.isCancelled, editing?.hashValue == identity { previewCounts = values }
            }
            .onAppear {
                if let id = activeProfileID, let p = profiles.first(where: { $0.id == id }) { load(p) }
                else if let p = profiles.first { load(p) }
            }
    }
    private func editor(_ profile: ProjectClassificationProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("项目显示名称", text: Binding(get: { editing?.name ?? "" }, set: { value in editing?.name = value }))
                    .font(.headline)
                ForEach(profile.roots, id: \.self) { root in Text(root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button("添加链接目录…") { addRoot() }
                    Button("发现索引", action: discover)
                    Button("选择索引文件…", action: chooseIndex)
                }
                Text("选择一份或多份索引").font(.headline)
                if candidates.isEmpty { Text("尚未发现索引，可手动选择项目目录内的 Markdown 文件。").font(.caption).foregroundStyle(.secondary) }
                ForEach(candidates, id: \.self) { path in
                    Toggle(isOn: Binding(get: { selectedPaths.contains(path) }, set: { value in
                        if value { selectedPaths.insert(path) } else { selectedPaths.remove(path) }; hasPreview = false
                    })) { Text(relative(path, roots: profile.roots)).font(.caption).lineLimit(2).help(path) }
                }
                Button(original == nil ? "解析并预览" : "刷新并预览差异", systemImage: "arrow.clockwise", action: parse)
                    .disabled(selectedPaths.isEmpty)
                if !difference.isEmpty { Text(difference).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundStyle(.orange) }
                Divider()
                if !profile.dimensions.isEmpty {
                    Text("分类预览与校正").font(.headline)
                    Text("置顶与手动顺序优先；合并仅限同一维度。数量是去重后的已入库素材数。").font(.caption).foregroundStyle(.secondary)
                    ForEach(profile.orderedDimensions) { dimension in dimensionEditor(dimension, profile: profile) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).textFieldStyle(.roundedBorder).padding(.trailing, 4)
        }
    }
    private func dimensionEditor(_ dimension: ProjectClassificationDimension, profile: ProjectClassificationProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("分类名称", text: Binding(get: { currentDimension(dimension.id)?.name ?? dimension.name }, set: { value in changeDimension(dimension.id) { $0.displayName = value } }))
                Toggle("置顶", isOn: Binding(get: { currentDimension(dimension.id)?.pinned ?? false }, set: { value in changeDimension(dimension.id) { $0.pinned = value } })).fixedSize()
                Button { moveDimension(dimension.id, delta: -1) } label: { Image(systemName: "arrow.up") }.help("前移分类")
                Button { moveDimension(dimension.id, delta: 1) } label: { Image(systemName: "arrow.down") }.help("后移分类")
            }
            ForEach(dimension.orderedOptions) { option in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("选项名称", text: Binding(get: { currentOption(option.id, dimension: dimension.id)?.name ?? option.name }, set: { value in changeOption(option.id, dimension: dimension.id) { $0.displayName = value } }))
                        Text((previewCounts[dimension.id]?[option.id].map { "\($0) 项" } ?? "统计中") + (option.unavailable ? " · 已移除" : "")).font(.caption).foregroundStyle(.secondary).fixedSize()
                        Menu {
                            Button(option.pinned ? "取消置顶" : "置顶") { changeOption(option.id, dimension: dimension.id) { $0.pinned.toggle() } }
                            Button("前移") { moveOption(option.id, dimension: dimension.id, delta: -1) }
                            Button("后移") { moveOption(option.id, dimension: dimension.id, delta: 1) }
                            Menu("合并到") {
                                ForEach(dimension.options.filter { $0.id != option.id }) { target in Button(target.name) { merge(option.id, into: target.id, dimension: dimension.id) } }
                            }
                            Button("指定已入库素材…") { associate(option.id, dimension: dimension.id, directory: false) }
                            Button("指定链接目录…") { associate(option.id, dimension: dimension.id, directory: true) }
                            Button("清除人工关联") { changeOption(option.id, dimension: dimension.id) { $0.manualPaths = []; $0.manualMaterialIDs = [] } }
                        } label: { Image(systemName: "ellipsis.circle") }.fixedSize().help("顺序、合并和素材关联")
                    }
                    if let evidence = option.evidence.first {
                        Text("来源：\((evidence.path as NSString).lastPathComponent):\(evidence.line) · \(evidence.text)").font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    ForEach(Array(option.warnings.enumerated()), id: \.offset) { _, text in Text(text).font(.caption2).foregroundStyle(.orange) }
                    if !option.manualPaths.isEmpty { Text("人工目录：" + option.manualPaths.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.leading, 10)
            }
        }.padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
    private func load(_ p: ProjectClassificationProfile) {
        editing = p; original = p; selectedPaths = Set(p.sources.map(\.path)); candidates = p.sources.map(\.path)
        previewSources = p.sources; hasPreview = true; parsedNewSources = false; issue = nil; warnings = []; difference = ""
        discover()
    }
    private func addProject() {
        guard let roots = chooseFiles(directories: true), !roots.isEmpty else { return }
        begin(name: URL(fileURLWithPath: roots[0]).lastPathComponent, roots: roots)
    }
    private func begin(name: String, roots: [String], id: String? = nil) {
        if let saved = profiles.first(where: { $0.id == id || Set($0.roots) == Set(roots) }) { load(saved); return }
        var fresh = ProjectClassificationProfile(name: name, roots: roots)
        if let id { fresh.id = id }
        editing = fresh
        original = nil; candidates = []; selectedPaths = []; hasPreview = false; warnings = []; issue = nil; difference = ""
        discover()
    }
    private func addRoot() {
        guard let roots = chooseFiles(directories: true), var profile = editing else { return }
        for root in roots where !profile.roots.contains(root) { profile.roots.append(root) }
        editing = profile; hasPreview = false; discover()
    }
    private func chooseIndex() {
        guard let paths = chooseFiles(directories: false), let profile = editing else { return }
        let valid = paths.filter { ProjectClassificationParser.isWithin($0, roots: profile.roots) }
        if valid.count != paths.count { issue = "索引必须位于该项目已经链接的目录内。" }
        candidates = Array(Set(candidates + valid)).sorted(); selectedPaths.formUnion(valid); hasPreview = false
    }
    private func discover() {
        guard let profile = editing else { return }
        busy = true
        Task {
            do {
                let found = try await Task.detached(priority: .utility) { try ProjectClassificationParser.discover(roots: profile.roots) }.value
                if editing?.id == profile.id { candidates = Array(Set(found + profile.sources.map(\.path) + Array(selectedPaths))).sorted() }
            } catch { issue = error.localizedDescription }
            busy = false
        }
    }
    private func parse() {
        guard let p = editing else { return }
        let paths = selectedPaths.sorted(), materials = store.materials
        busy = true; issue = nil
        Task {
            do {
                let draft = try await Task.detached(priority: .utility) { try ProjectClassificationParser.parse(roots: p.roots, indexPaths: paths, materials: materials) }.value
                guard editing?.id == p.id else { busy = false; return }
                let next = ProjectClassificationParser.adopting(draft, into: p)
                let before = Set(p.dimensions.flatMap { $0.options.filter { !$0.unavailable }.map(\.id) })
                let after = Set(next.dimensions.flatMap { $0.options.filter { !$0.unavailable }.map(\.id) })
                difference = "新增 \(after.subtracting(before).count) 项，移除 \(before.subtracting(after).count) 项；旧的失效条件保留供核对。"
                editing = next; previewSources = draft.sources; warnings = draft.warnings; hasPreview = true; parsedNewSources = true
            } catch { issue = "解析失败，已采用的分类保持原样：" + error.localizedDescription; hasPreview = false }
            busy = false
        }
    }
    private func adopt() {
        guard var p = editing, hasPreview else { return }
        guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { issue = "请填写项目名称。"; return }
        let sources = previewSources, expected = original
        if parsedNewSources { p.issue = nil }
        busy = true
        let validateSources = parsedNewSources
        let adopted = p
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    for source in sources where validateSources {
                        guard ProjectClassificationParser.isWithin(source.path, roots: adopted.roots),
                              try ProjectClassificationParser.fingerprint(source.path) == source.fingerprint else {
                            throw MaterialDatabase.error("来源已变化，请重新预览后采用。")
                        }
                    }
                }.value
                try await store.changeTagging("项目分类已保存", undoable: true) { state, _ in
                    var profiles = state.projectClassifications ?? []
                    guard profiles.first(where: { $0.id == adopted.id }) == expected else { throw MaterialDatabase.error("项目配置已被其他操作修改，请重新打开核对。") }
                    profiles.removeAll { $0.id == adopted.id }; profiles.append(adopted)
                    state.projectClassifications = profiles
                }
                activeProfileID = adopted.id; original = adopted; editing = adopted; hasPreview = true; parsedNewSources = false
                issue = nil
            } catch { issue = error.localizedDescription }
            busy = false
        }
    }
    private func currentDimension(_ id: String) -> ProjectClassificationDimension? { editing?.dimensions.first { $0.id == id } }
    private func currentOption(_ id: String, dimension: String) -> ProjectClassificationOption? { currentDimension(dimension)?.options.first { $0.id == id } }
    private func changeDimension(_ id: String, _ action: (inout ProjectClassificationDimension) -> Void) {
        guard var p = editing, let i = p.dimensions.firstIndex(where: { $0.id == id }) else { return }
        action(&p.dimensions[i]); editing = p
    }
    private func changeOption(_ id: String, dimension: String, _ action: (inout ProjectClassificationOption) -> Void) {
        changeDimension(dimension) { d in guard let i = d.options.firstIndex(where: { $0.id == id }) else { return }; action(&d.options[i]) }
    }
    private func moveDimension(_ id: String, delta: Int) {
        guard var p = editing else { return }; var ordered = p.orderedDimensions
        guard let i = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(i + delta) else { return }
        ordered.swapAt(i, i + delta)
        for (n, d) in ordered.enumerated() { if let j = p.dimensions.firstIndex(where: { $0.id == d.id }) { p.dimensions[j].manualOrder = n } }
        editing = p
    }
    private func moveOption(_ id: String, dimension: String, delta: Int) {
        changeDimension(dimension) { d in
            var ordered = d.orderedOptions
            guard let i = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(i + delta) else { return }
            ordered.swapAt(i, i + delta)
            for (n, option) in ordered.enumerated() { if let j = d.options.firstIndex(where: { $0.id == option.id }) { d.options[j].manualOrder = n } }
        }
    }
    private func merge(_ source: String, into target: String, dimension: String) {
        changeDimension(dimension) { d in
            guard let a = d.options.first(where: { $0.id == source }), let i = d.options.firstIndex(where: { $0.id == target }) else { return }
            d.options[i].mergedIDs.formUnion(a.mergedIDs.union([source])); d.options[i].materialIDs.formUnion(a.materialIDs)
            d.options[i].manualMaterialIDs.formUnion(a.manualMaterialIDs); d.options[i].manualPaths = Array(Set(d.options[i].manualPaths + a.manualPaths))
            d.options[i].evidence += a.evidence; d.options.removeAll { $0.id == source }
        }
        if editing?.selected[dimension]?.contains(source) == true { editing?.selected[dimension]?.remove(source); editing?.selected[dimension]?.insert(target) }
    }
    private func associate(_ id: String, dimension: String, directory: Bool) {
        guard let paths = chooseFiles(directories: directory), let profile = editing else { return }
        guard paths.allSatisfy({ ProjectClassificationParser.isWithin($0, roots: profile.roots) }) else { issue = "只能关联本项目已链接目录内的文件或目录。"; return }
        if directory { changeOption(id, dimension: dimension) { $0.manualPaths = Array(Set($0.manualPaths + paths)) }; return }
        var matches = Set<String>()
        for path in paths {
            let found = store.materials.filter { record in
                record.deletedAt == nil && ([record.sourcePath].compactMap { $0 } + record.sourceLocations).contains { ProjectClassificationParser.canonical($0) == ProjectClassificationParser.canonical(path) }
            }
            guard found.count == 1, let record = found.first else { issue = "所选文件未入库或存在多个匹配，未修改关联。"; return }
            matches.insert(record.id)
        }
        changeOption(id, dimension: dimension) { $0.manualMaterialIDs.formUnion(matches) }
    }
    private func chooseFiles(directories: Bool) -> [String]? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directories; panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = true; panel.canCreateDirectories = false
        panel.prompt = directories ? "链接所选目录" : "选择文件"
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.map { ProjectClassificationParser.canonical($0.path) }
    }
    private func relative(_ path: String, roots: [String]) -> String {
        for root in roots where path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }
}
