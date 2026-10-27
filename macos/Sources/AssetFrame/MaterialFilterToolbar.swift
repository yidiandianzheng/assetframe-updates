import SwiftUI
import AppKit

/// 自动换行的胶囊行；标签多了自动折到下一行，不用手写嵌套 HStack。
///
/// 关键约束：单个项目永远不超过可用宽度。旧实现用 `.unspecified` 量尺寸，
/// 遇到超长中文名会按理想宽度占位，把整行撑出中间内容区（截图里的横向溢出）。
/// 现在先按可用宽度量一次，再把超宽项目压到可用宽度内，由文字自己截断。
private struct WrappingRow: Layout {
    var spacing: Double = 6
    var lineSpacing: Double = 6
    /// 理想宽度上限：窗口会按内容理想宽度打开，不加约束时一整排胶囊会把窗口撑得很宽。
    private static let idealWidthCap = 720.0

    private func itemSize(_ subview: LayoutSubview, available: Double) -> CGSize {
        let size = subview.sizeThatFits(ProposedViewSize(width: available.isFinite ? available : nil, height: nil))
        guard available.isFinite else { return size }
        return CGSize(width: min(size.width, available), height: size.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let finiteWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let available = finiteWidth ?? Self.idealWidthCap
        var x = 0.0, y = 0.0, lineHeight = 0.0, widest = 0.0
        for subview in subviews {
            let size = itemSize(subview, available: available)
            if x > 0, x + size.width > available { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        // 有确定宽度时如实上报该宽度（行由外层撑满，折行也按这个宽度算）；
        // 只有理想尺寸查询才回落到内容宽度，避免把窗口理想宽度推到屏幕宽。
        let width = finiteWidth ?? min(widest, Self.idealWidthCap)
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let available = bounds.width
        var x = bounds.minX, y = bounds.minY, lineHeight = 0.0
        for subview in subviews {
            let size = itemSize(subview, available: available)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct MaterialFilterToolbar: View {
    @Binding var filter: MaterialSearchFilter
    let materials: [MaterialRecord]
    let revision: Int
    /// 当前筛选结果条数，用于已选条件条上的“结果数”；由调用方传入，不另算一套口径。
    var resultCount: Int = 0
    @State private var kindCounts: [MaterialKind: Int] = [:]
    @State private var availableTags: [String] = []
    /// 维度 → 词 → 当前库里有多少张图带这个值；用于菜单和分类面板里直接显示可选数量。
    @State private var facetCounts: [String: [String: Int]] = [:]
    /// 品牌 → 茶类 → 数量；品牌卡片上显示「乌龙茶·红茶 100 张」。
    @State private var brandTeaCounts: [String: [String: Int]] = [:]
    /// 品牌 → 产品线 → 数量；品牌卡片下面的产品线胶囊。
    @State private var brandLineCounts: [String: [String: Int]] = [:]
    @State private var brandOrder: [String] = []
    let formatCounts: [String: Int]
    let folders: [LocalFolderSource]
    @State private var showFormats = false
    @State private var formatSearch = ""
    var showsMore = false
    let onMore: () -> Void
    var tagging: MaterialTaggingState = .init()
    /// 分类面板由外部（左侧栏「当前分类」入口）控制展开/收起。
    /// 这里不再自己持有 @AppStorage，避免出现两个开关状态互相打架。
    @Binding var classificationPanelExpanded: Bool
    static let colors = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbarRow
            // 已选条件条：收起面板后仍然可见，能逐个移除、看到结果数并清除。
            if classificationFilterCount > 0 {
                Divider()
                conditionsBar
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if classificationPanelExpanded {
                Divider()
                classificationPanel
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(isPresented: $showFormats, arrowEdge: .bottom) { formatPanel }
        .task(id: revision) {
            let snapshot = materials
            let worker = Task.detached(priority: .utility) {
                let active = snapshot.filter { $0.deletedAt == nil }
                var termCounts: [String: [String: Int]] = [:]
                var brandTea: [String: [String: Int]] = [:]
                var brandLine: [String: [String: Int]] = [:]
                for record in active {
                    guard let classification = record.classification else { continue }
                    for (dimension, terms) in classification.values {
                        for term in terms { termCounts[dimension, default: [:]][term, default: 0] += 1 }
                    }
                    guard let brand = classification.terms(for: "brand").first else { continue }
                    for tea in classification.terms(for: "tea_type") { brandTea[brand, default: [:]][tea, default: 0] += 1 }
                    for line in classification.terms(for: "product_line") { brandLine[brand, default: [:]][line, default: 0] += 1 }
                }
                return (Dictionary(grouping: active, by: \.kind).mapValues(\.count),
                        Set(active.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                        termCounts,
                        brandTea,
                        brandLine)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            kindCounts = result.0
            availableTags = result.1
            facetCounts = result.2
            brandTeaCounts = result.3
            brandLineCounts = result.4
            // 词表里的品牌始终列出（当前库没数据也显示 0 张），按数量从多到少排。
            let known = ClassificationVocabulary.terms(in: "brand").map(\.canonical)
            let all = Set(known).union(result.4.keys)
            brandOrder = all.sorted { lhs, rhs in
                let left = result.2["brand"]?[lhs] ?? 0
                let right = result.2["brand"]?[rhs] ?? 0
                if left != right { return left > right }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }

    private var toolbarRow: some View {
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
            .padding(.horizontal, 10).padding(.vertical, 8)
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
        // 分类管理面板入口已移到左侧栏「当前分类」；这里只保留按维度展开的「全部分类」菜单。
        Menu("全部分类", systemImage: "square.grid.3x3") {
            Button("不限分类") { filter.classificationFilters = nil }
            Text("维度之间同时满足；同维度多选任一即可")
            ForEach(ClassificationVocabulary.dimensions) { dimension in
                Menu(dimension.name) { facetItems(dimension.id, dimension.name) }
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
    // MARK: 分类面板

    /// 分类管理面板：左侧固定标签列 + 可换行选项行。
    /// 所有选项按内容宽度排布，既不会撑出中间内容区，也不把原生菜单拉满整行。
    private var classificationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("分类筛选", systemImage: "square.grid.2x2").font(.caption).bold()
                Text("同维度多选任一，跨维度同时满足").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                Button { classificationPanelExpanded = false } label: {
                    Label("收起", systemImage: "chevron.up").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("收起分类面板；已选条件仍显示在工具栏下方")
            }
            classificationRow("品牌") { brandOptions }
            classificationRow("产品线") { productLineOptions }
            classificationRow("茶类") { pillOptions("tea_type") }
            classificationRow("用途") { pillOptions("usage") }
            classificationRow("状态") { statusOptions }
            classificationRow("更多筛选") { moreFilterOptions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 左侧标签固定宽度：每一行的标题和“全部”都从同一个可见起点开始，不会被推出可视区。
    private func classificationRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
                .padding(.top, 5)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 品牌 / 产品线

    private var selectedBrands: [String] { (filter.classificationFilters?["brand"] ?? []).sorted() }
    private var selectedLines: [String] { (filter.classificationFilters?["product_line"] ?? []).sorted() }

    private var brandOptions: some View {
        WrappingRow(spacing: 6) {
            pill("全部", selected: selectedBrands.isEmpty, count: nil, help: "不限品牌") { clearFacet("brand") }
            ForEach(brandOptionNames, id: \.self) { brand in
                pill(brand, selected: selectedBrands.contains(brand), count: facetCounts["brand"]?[brand] ?? 0,
                     help: brandHelp(brand)) {
                    toggleFacet(brand, dimension: "brand")
                }
            }
        }
    }

    /// 词表里 0 张的品牌也照常列出；已选但当前词表/数据都没有的品牌插到最前，避免静默丢条件。
    private var brandOptionNames: [String] {
        let missing = selectedBrands.filter { !brandOrder.contains($0) }
        return missing + brandOrder
    }

    private func brandHelp(_ brand: String) -> String {
        var parts = ["按「\(brand)」筛选"]
        let teas = (brandTeaCounts[brand] ?? [:]).sorted { $0.value > $1.value }
        if !teas.isEmpty { parts.append("茶类：" + teas.map { "\($0.key) \($0.value)" }.joined(separator: "、")) }
        let lines = brandLineCounts[brand] ?? [:]
        if !lines.isEmpty {
            parts.append("产品线 \(lines.count) 条：" + lines.sorted { $0.value > $1.value }.map(\.key).joined(separator: "、"))
        }
        return parts.joined(separator: "\n")
    }

    private var productLineOptions: some View {
        WrappingRow(spacing: 6) {
            if selectedBrands.isEmpty {
                // 没有品牌限定时，用折叠菜单承载全部产品线，不占整行。
                Menu { productLineMenuItems } label: {
                    chipLabel("全部产品线", count: selectedLines.count, systemImage: "shippingbox")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("按品牌分组列出全部产品线")
                ForEach(selectedLines, id: \.self) { line in
                    pill(line, selected: true, count: facetCounts["product_line"]?[line] ?? 0) {
                        toggleFacet(line, dimension: "product_line")
                    }
                }
            } else {
                // 已选品牌时按这些品牌组织产品线；不截断，全部可点。
                ForEach(selectedBrands, id: \.self) { brand in
                    ForEach(productLines(for: brand), id: \.key) { item in
                        pill(item.key, selected: selectedLines.contains(item.key), count: item.value) {
                            toggleFacet(item.key, dimension: "product_line")
                        }
                    }
                }
                // 旧选择不在当前品牌展示集合内：保留并显示，点一下才移除。
                ForEach(orphanSelectedLines, id: \.self) { line in
                    pill(line, selected: true, count: facetCounts["product_line"]?[line] ?? 0,
                         help: "当前品牌下没有这条产品线；原选择仍保留，点一下移除") {
                        toggleFacet(line, dimension: "product_line")
                    }
                }
            }
        }
    }

    private func productLines(for brand: String) -> [(key: String, value: Int)] {
        (brandLineCounts[brand] ?? [:]).sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
    }

    private var orphanSelectedLines: [String] {
        let covered = Set(selectedBrands.flatMap { productLines(for: $0).map(\.key) })
        return selectedLines.filter { !covered.contains($0) }
    }

    @ViewBuilder private var productLineMenuItems: some View {
        Button("不限产品线") { clearFacet("product_line") }
        Text("按品牌分组；同维度多选任一即可")
        ForEach(brandOrder, id: \.self) { brand in
            let lines = productLines(for: brand)
            if !lines.isEmpty {
                Menu("\(brand)（\(lines.count)）") {
                    ForEach(lines, id: \.key) { item in
                        Toggle("\(item.key)（\(item.value)）", isOn: classificationBinding(item.key, dimension: "product_line"))
                    }
                }
            }
        }
        let covered = Set(brandOrder.flatMap { productLines(for: $0).map(\.key) })
        let rest = classificationNames("product_line").filter { !covered.contains($0) }
        if !rest.isEmpty {
            Menu("其他产品线（\(rest.count)）") {
                ForEach(rest, id: \.self) { name in
                    Toggle(facetOptionLabel(name, dimension: "product_line"), isOn: classificationBinding(name, dimension: "product_line"))
                }
            }
        }
    }

    // MARK: 茶类 / 用途 / 状态 / 更多筛选

    private func pillOptions(_ dimension: String) -> some View {
        let selected = filter.classificationFilters?[dimension] ?? []
        return WrappingRow(spacing: 6) {
            pill("全部", selected: selected.isEmpty, count: nil, help: "不限") { clearFacet(dimension) }
            ForEach(classificationNames(dimension), id: \.self) { name in
                pill(name, selected: selected.contains(name), count: facetCounts[dimension]?[name] ?? 0) {
                    toggleFacet(name, dimension: dimension)
                }
            }
        }
    }

    private var statusOptions: some View {
        WrappingRow(spacing: 6) {
            Menu { facetItems("acceptance", "验收状态") } label: {
                chipLabel("验收状态", count: (filter.classificationFilters?["acceptance"] ?? []).count, systemImage: "checkmark.seal")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu { facetItems("organize_status", "整理状态") } label: {
                chipLabel("整理状态", count: (filter.classificationFilters?["organize_status"] ?? []).count, systemImage: "tray.full")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var moreFilterOptions: some View {
        WrappingRow(spacing: 6) {
            Menu { facetItems("asset_kind", "图类型") } label: {
                chipLabel("图类型", count: (filter.classificationFilters?["asset_kind"] ?? []).count, systemImage: "photo.on.rectangle.angled")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu { facetItems("ratio", "比例") } label: {
                chipLabel("比例", count: (filter.classificationFilters?["ratio"] ?? []).count, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu { facetItems("shot", "机位") } label: {
                chipLabel("机位", count: (filter.classificationFilters?["shot"] ?? []).count, systemImage: "camera")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func chipLabel(_ title: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(count == 0 ? title : "\(title) · \(count)").font(.caption).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.secondary.opacity(count == 0 ? 0.10 : 0.20), in: Capsule())
        .foregroundStyle(count == 0 ? Color.primary : Color.accentColor)
        .contentShape(Capsule())
    }

    private func pill(_ title: String, selected: Bool, count: Int?, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if let count {
                    Text("\(count)").monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? (count.map { "\(title)：\($0) 张" } ?? title))
    }

    // MARK: 已选条件条

    private struct ConditionChip: Identifiable {
        let dimension: String
        let label: String
        let value: String
        var id: String { dimension + "|" + value }
    }

    /// 收起面板后仍保留：逐个移除、结果数、清除入口都在这里。
    private var conditionsBar: some View {
        WrappingRow(spacing: 6) {
            Text("已选").font(.caption).foregroundStyle(.secondary)
            ForEach(conditionChips, id: \.id) { chip in
                Button { toggleFacet(chip.value, dimension: chip.dimension) } label: {
                    HStack(spacing: 4) {
                        Text("\(chip.label)：\(chip.value)").font(.caption).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("移除「\(chip.label)：\(chip.value)」")
            }
            Text("结果 \(resultCount) 项").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button("清除分类") { filter.classificationFilters = nil }
                .font(.caption).buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                .help("清除全部分类条件，其他筛选保持不动")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conditionChips: [ConditionChip] {
        let order = ["brand", "product_line", "tea_type", "usage", "acceptance", "organize_status", "asset_kind", "ratio", "shot"]
        let values = filter.classificationFilters ?? [:]
        var chips: [ConditionChip] = []
        for dimension in order {
            for value in (values[dimension] ?? []).sorted() {
                chips.append(ConditionChip(dimension: dimension, label: dimensionName(dimension), value: value))
            }
        }
        for dimension in values.keys.sorted() where !order.contains(dimension) {
            for value in (values[dimension] ?? []).sorted() {
                chips.append(ConditionChip(dimension: dimension, label: dimensionName(dimension), value: value))
            }
        }
        return chips
    }

    private func dimensionName(_ id: String) -> String {
        ClassificationVocabulary.dimensions.first { $0.id == id }?.name ?? id
    }

    // MARK: 公共筛选操作

    @ViewBuilder private func facetItems(_ dimension: String, _ label: String) -> some View {
        Button("不限\(label)") { clearFacet(dimension) }
        Text("同维度多选任一即可")
        ForEach(classificationNames(dimension), id: \.self) { name in
            Toggle(facetOptionLabel(name, dimension: dimension), isOn: classificationBinding(name, dimension: dimension))
        }
    }

    private func toggleFacet(_ term: String, dimension: String) {
        var values = filter.classificationFilters ?? [:]
        var terms = values[dimension] ?? []
        if terms.contains(term) { terms.remove(term) } else { terms.insert(term) }
        if terms.isEmpty { values.removeValue(forKey: dimension) } else { values[dimension] = terms }
        filter.classificationFilters = values.isEmpty ? nil : values
        // 不强制展开：删掉一个条件时保持用户当前的展开/收起选择，条件条继续显示剩余项。
    }

    private func facetOptionLabel(_ name: String, dimension: String) -> String {
        "\(name)（\(facetCounts[dimension]?[name] ?? 0)）"
    }

    private func clearFacet(_ dimension: String) {
        var values = filter.classificationFilters ?? [:]
        values.removeValue(forKey: dimension)
        filter.classificationFilters = values.isEmpty ? nil : values
    }

    private var ratingTitle: String {
        if let rating = filter.exactRating { return rating == 0 ? "未评分" : "\(rating) 星" }
        return filter.minimumRating == 0 ? "评分" : "≥\(filter.minimumRating)星"
    }
    private var classificationFilterCount: Int {
        (filter.classificationFilters ?? [:]).values.reduce(0) { $0 + $1.count }
    }
    /// 左侧栏「当前分类」入口要显示已选数量；由浏览器层读取，避免复制一套计数口径。
    var activeClassificationCount: Int { classificationFilterCount }
    private func classificationNames(_ dimension: String) -> [String] {
        let saved = materials.lazy.flatMap { $0.classification?.terms(for: dimension) ?? [] }
        // 词表里的标准选项始终可选：即使当前库还没有该值，也能先按电商分类口径筛。
        let vocabulary = ClassificationVocabulary.terms(in: dimension).map(\.canonical)
        return Set(tagging.effectiveTerms.filter { $0.dimension == dimension && $0.enabled }.map(\.name))
            .union(saved).union(vocabulary).union(filter.classificationFilters?[dimension] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
