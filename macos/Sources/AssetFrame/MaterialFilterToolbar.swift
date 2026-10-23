import SwiftUI

struct MaterialFilterToolbar: View {
    @Binding var filter: MaterialSearchFilter
    let materials: [MaterialRecord]
    let revision: Int
    @State private var kindCounts: [MaterialKind: Int] = [:]
    @State private var availableTags: [String] = []
    let formatCounts: [String: Int]
    let folders: [LocalFolderSource]
    @State private var showFormats = false
    @State private var formatSearch = ""
    var showsMore = false
    let onMore: () -> Void
    var tagging: MaterialTaggingState = .init()
    static let colors = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色"]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { firstGroup; secondGroup; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { firstGroup; Spacer(minLength: 0) }
                HStack(spacing: 10) { secondGroup; Spacer(minLength: 0) }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) { firstGroup; secondGroup }.fixedSize()
            }.scrollIndicators(.hidden)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
            .popover(isPresented: $showFormats, arrowEdge: .bottom) { formatPanel }
            .task(id: revision) {
                let snapshot = materials
                let worker = Task.detached(priority: .utility) {
                    let active = snapshot.filter { $0.deletedAt == nil }
                    return (Dictionary(grouping: active, by: \.kind).mapValues(\.count),
                            Set(active.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
                }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                kindCounts = result.0; availableTags = result.1
            }
    }
    @ViewBuilder private var firstGroup: some View {
        MaterialKindFilterButton(
            selectedKinds: $filter.kinds,
            selectedFormats: $filter.formats,
            counts: kindCounts
        )
        .foregroundStyle(filter.kinds.isEmpty ? Color.primary : Color.accentColor)
        Menu(title("颜色", filter.colorLabels?.count ?? 0), systemImage: "circle.lefthalf.filled") {
            Text("手动颜色标记，不是图片主色识别")
            Button("不限颜色") { filter.colorLabels = nil }
            ForEach(Self.colors + ["未标记"], id: \.self) { color in
                Toggle(color, isOn: selected(color, keyPath: \.colorLabels))
            }
        }
        .foregroundStyle((filter.colorLabels ?? []).isEmpty ? Color.primary : Color.accentColor)
        Menu(title("标签", filter.requiredTags?.count ?? 0), systemImage: "tag") {
            Text("同时包含所选标签")
            Button("不限标签") { filter.requiredTags = nil }
            let tags = Set(availableTags).union(filter.requiredTags ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if tags.isEmpty { Text("暂无标签，可在右侧素材信息中添加") }
            ForEach(tags, id: \.self) { tag in Toggle(tag, isOn: selected(tag, keyPath: \.requiredTags)) }
        }
        .foregroundStyle((filter.requiredTags ?? []).isEmpty ? Color.primary : Color.accentColor)
        Menu(classificationTitle, systemImage: "square.grid.2x2") {
            Button("不限分类") { filter.classificationFilters = nil }
            Text("维度之间同时满足；同维度多选任一即可")
            ForEach(ClassificationVocabulary.dimensions) { dimension in
                Menu(dimension.name) {
                    ForEach(classificationNames(dimension.id), id: \.self) { name in
                        Toggle(name, isOn: classificationBinding(name, dimension: dimension.id))
                    }
                }
            }
        }
        .foregroundStyle(classificationFilterCount == 0 ? Color.primary : Color.accentColor)
        Menu(title("文件夹", filter.folderPaths?.count ?? 0), systemImage: "folder") {
            Button("不限文件夹") { filter.folderPaths = nil }
            Text("包含子文件夹；多个目录满足任一即可")
            ForEach(folders) { folder in
                Menu(folder.name) {
                    Toggle("整个文件夹", isOn: selected(folder.rootPath, keyPath: \.folderPaths))
                    ForEach(LocalFolderTreeLayout.includingAncestors(folder.directoryPaths), id: \.self) { path in
                        Toggle(path, isOn: selected(URL(fileURLWithPath: folder.rootPath).appendingPathComponent(path).path, keyPath: \.folderPaths))
                    }
                }
            }
        }
        .foregroundStyle((filter.folderPaths ?? []).isEmpty ? Color.primary : Color.accentColor)
    }
    @ViewBuilder private var secondGroup: some View {
        Menu(filter.orientation == "全部" ? "形状" : filter.orientation, systemImage: "rectangle.split.2x1") {
            Picker("形状", selection: $filter.orientation) {
                ForEach(["全部", "横屏", "竖屏", "方形"], id: \.self) { Text($0).tag($0) }
            }
        }
        .foregroundStyle(filter.orientation == "全部" ? Color.primary : Color.accentColor)
        Menu(ratingTitle, systemImage: "star") {
            Button("不限评分") { filter.minimumRating = 0; filter.exactRating = nil }
            Button("未评分") { filter.minimumRating = 0; filter.exactRating = 0 }
            ForEach(1...5, id: \.self) { n in
                Button("\(n) 星及以上") { filter.minimumRating = n; filter.exactRating = nil }
            }
        }
        .foregroundStyle(filter.minimumRating == 0 && filter.exactRating == nil ? Color.primary : Color.accentColor)
        Button { showFormats.toggle() } label: {
            Label(title("格式", filter.formats.count), systemImage: "doc")
        }.buttonStyle(.plain)
            .foregroundStyle(filter.formats.isEmpty ? Color.primary : Color.accentColor)
        Button(showsMore ? "收起条件" : "更多条件", systemImage: "slider.horizontal.3", action: onMore)
            .buttonStyle(.borderless)
            .help("时长、分辨率与保存筛选组合")
        if filter.activeFacetCount > 0 {
            Button("清除筛选 · \(filter.activeFacetCount)", systemImage: "xmark.circle") { filter.resetFacets() }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help("清除全部筛选条件，保留当前目录、搜索文字和搜索范围")
        }
    }
    private var formatPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索格式…", text: $formatSearch).textFieldStyle(.plain)
                if !formatSearch.isEmpty { Button("清除格式搜索", systemImage: "xmark.circle.fill") { formatSearch = "" }.labelStyle(.iconOnly).buttonStyle(.plain).help("清除格式搜索") }
            }.padding(12)
            Divider()
            HStack(spacing: 6) {
                quickMediaButton("全部", kind: nil, systemImage: "square.grid.2x2")
                quickMediaButton("图片", kind: .image, systemImage: "photo")
                quickMediaButton("视频", kind: .video, systemImage: "film")
                quickMediaButton("音频", kind: .audio, systemImage: "waveform")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    let options = Set(formatCounts.keys).union(filter.formats).sorted().filter {
                        formatSearch.isEmpty || ($0.isEmpty ? "无扩展名" : $0).localizedCaseInsensitiveContains(formatSearch)
                    }
                    if options.isEmpty { Text("没有匹配格式").foregroundStyle(.secondary).padding() }
                    ForEach(options, id: \.self) { format in
                        Toggle(isOn: Binding(get: { filter.formats.contains(format) }, set: { on in
                            if on { filter.formats.insert(format) } else { filter.formats.remove(format) }
                        })) {
                            HStack {
                                Text(format.isEmpty ? "无扩展名" : format)
                                Spacer()
                                Text(formatCounts[format, default: 0], format: .number).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).padding(.horizontal, 10).padding(.vertical, 5)
                    }
                }.padding(.vertical, 6)
            }.frame(height: 310)
            Divider()
            HStack {
                Text("已选 \(filter.formats.count) 项").foregroundStyle(.secondary)
                Spacer()
                Button("清除此项") { filter.formats = [] }.disabled(filter.formats.isEmpty)
            }.font(.caption).padding(10)
        }.frame(width: 310)
            .onExitCommand { showFormats = false }
    }
    private func quickMediaButton(_ title: String, kind: MaterialKind?, systemImage: String) -> some View {
        let selected = kind.map { filter.kinds == [$0] } ?? filter.kinds.isEmpty
        return Button {
            filter.selectOnly(kind: kind)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(kind.map { "只显示\($0.rawValue)素材，并清除格式限定" } ?? "显示全部媒体类型，并清除格式限定")
    }
    private var ratingTitle: String {
        if let rating = filter.exactRating { return rating == 0 ? "未评分" : "\(rating) 星" }
        return filter.minimumRating == 0 ? "评分" : "≥\(filter.minimumRating)星"
    }
    private var classificationFilterCount: Int {
        (filter.classificationFilters ?? [:]).values.reduce(0) { $0 + $1.count }
    }
    private var classificationTitle: String {
        classificationFilterCount == 0 ? "分类" : "分类 · \(classificationFilterCount)"
    }
    private func classificationNames(_ dimension: String) -> [String] {
        let saved = materials.lazy.flatMap { $0.classification?.terms(for: dimension) ?? [] }
        return Set(tagging.effectiveTerms.filter { $0.dimension == dimension && $0.enabled }.map(\.name))
            .union(saved).union(filter.classificationFilters?[dimension] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func classificationBinding(_ name: String, dimension: String) -> Binding<Bool> {
        Binding(get: {
            (filter.classificationFilters?[dimension] ?? []).contains(name)
        }, set: { on in
            var values = filter.classificationFilters ?? [:]
            var terms = values[dimension] ?? []
            if on { terms.insert(name) } else { terms.remove(name) }
            if terms.isEmpty { values.removeValue(forKey: dimension) } else { values[dimension] = terms }
            filter.classificationFilters = values.isEmpty ? nil : values
        })
    }
    private func title(_ name: String, _ count: Int) -> String { count == 0 ? name : "\(name) · \(count)" }
    private func selected(_ value: String, keyPath: WritableKeyPath<MaterialSearchFilter, Set<String>?>) -> Binding<Bool> {
        Binding(get: { (filter[keyPath: keyPath] ?? []).contains(value) }, set: { on in
            var values = filter[keyPath: keyPath] ?? []
            if on { values.insert(value) } else { values.remove(value) }
            filter[keyPath: keyPath] = values.isEmpty ? nil : values
        })
    }
}
