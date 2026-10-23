import SwiftUI

struct LocalFolderSelection: Hashable {
    var sourceID: String
    var relativePath: String
}

struct LocalFolderSidebarSection: View {
    @ObservedObject var store: AssetStore
    @Binding var selection: LocalFolderSelection?
    let currentProjectStarCounts: [Int: Int]
    let currentProjectFiveStarCategoryCounts: [FiveStarAssetCategory: Int]
    let globalFiveStarCount: Int
    let allImportedFolderAssetCount: Int
    let isAllImportedFoldersSelected: Bool
    let isCurrentProjectAssetsSelected: Bool
    let selectedCurrentProjectRating: Int?
    let selectedCurrentProjectFiveStarCategory: FiveStarAssetCategory?
    let isGlobalFiveStarSelected: Bool
    let onSelectCurrentProjectAssets: () -> Void
    let onSelectCurrentProjectRating: (Int) -> Void
    let onSelectCurrentProjectFiveStarCategory: (FiveStarAssetCategory) -> Void
    let onSelectGlobalFiveStar: () -> Void
    let onSelectAllImportedFolders: () -> Void
    let onSelect: (LocalFolderSelection) -> Void
    @Binding var folderScope: LocalFolderScope
    let searchQuery: String
    let quickAccessItems: [SidebarQuickAccessItem]
    let onToggleQuickAccess: (SidebarQuickAccessItem) -> Void
    let onFolderRenamed: (String, String, String) -> Void
    @State private var focusedSourceID: String?
    @State private var hasAppliedDefaultFocus = false
    @State private var showsCurrentProjectRatings = true
    @State private var showsFiveStarCategories = false

    private var showsProjectSection: Bool {
        SidebarSearchMatcher.matches(
            searchQuery,
            candidates: ["当前项目资产", "星级资产", "五星", "4 星", "3 星", "2 星", "1 星", "通用资产"]
        )
    }

    private var visibleFolders: [LocalFolderSource] {
        store.localFolders.filter { folder in
            SidebarSearchMatcher.matches(
                searchQuery,
                candidates: [folder.sidebarDisplayName, folder.rootPath] + folder.directoryPaths
            )
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if showsProjectSection {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前项目")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.top, 2)

                CurrentProjectOverviewRow(
                    assetCount: store.activeAssets.count + store.pendingImports.count,
                    isSelected: isCurrentProjectAssetsSelected,
                    isExpanded: showsCurrentProjectRatings,
                    toggleExpansion: { showsCurrentProjectRatings.toggle() },
                    showProjectAssets: onSelectCurrentProjectAssets
                )

                if showsCurrentProjectRatings || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FiveStarRatingDirectoryRow(
                        count: currentProjectStarCounts[5, default: 0],
                        isSelected: selectedCurrentProjectRating == 5 && selectedCurrentProjectFiveStarCategory == nil,
                        isExpanded: showsFiveStarCategories,
                        onToggleExpansion: { showsFiveStarCategories.toggle() },
                        action: { onSelectCurrentProjectRating(5) }
                    )
                    if showsFiveStarCategories || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(FiveStarAssetCategory.allCases) { category in
                            FiveStarDirectoryButton(
                                title: category.rawValue,
                                count: currentProjectFiveStarCategoryCounts[category, default: 0],
                                isSelected: selectedCurrentProjectFiveStarCategory == category,
                                helpText: "只显示当前项目五星中的\(category.rawValue)资产",
                                indentation: 46,
                                systemImage: category.systemImage,
                                action: { onSelectCurrentProjectFiveStarCategory(category) }
                            )
                        }
                    }
                    ForEach([4, 3, 2, 1], id: \.self) { rating in
                        FiveStarDirectoryButton(
                            title: "\(rating) 星",
                            count: currentProjectStarCounts[rating, default: 0],
                            isSelected: selectedCurrentProjectRating == rating,
                            helpText: "显示当前项目中评为 \(rating) 星的图片",
                            indentation: 23,
                            action: { onSelectCurrentProjectRating(rating) }
                        )
                    }
                }
                FiveStarDirectoryButton(
                    title: "通用资产",
                    count: globalFiveStarCount,
                    isSelected: isGlobalFiveStarSelected,
                    helpText: "汇总所有明确加入通用库的资产，不限评分；同一文件只显示一次",
                    action: onSelectGlobalFiveStar
                )
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }

            if !store.localFolders.isEmpty,
               SidebarSearchMatcher.matches(searchQuery, candidates: ["已链接文件夹资产", "全部文件夹资产"]) {
                AllImportedFoldersButton(
                    count: allImportedFolderAssetCount,
                    isSelected: isAllImportedFoldersSelected,
                    action: onSelectAllImportedFolders
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }

            HStack {
                Text("文件夹")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("链接文件夹", systemImage: "plus", action: store.chooseLocalFolder)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("链接已有文件夹并保留完整目录结构")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)

            if store.localFolders.isEmpty {
                Button(action: store.chooseLocalFolder) {
                    Label("链接本地文件夹…", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 6))
                .padding(.horizontal, 4)
            } else {
                ForEach(visibleFolders) { folder in
                    LocalFolderSourceRow(
                        store: store,
                        folder: folder,
                        selection: $selection,
                        focusedSourceID: $focusedSourceID,
                        folderScope: $folderScope,
                        searchQuery: searchQuery,
                        quickAccessItems: quickAccessItems,
                        onToggleQuickAccess: onToggleQuickAccess,
                        onFolderRenamed: onFolderRenamed,
                        onSelect: onSelect
                    )
                }
            }
        }
        .onAppear(perform: applyDefaultFocusIfNeeded)
        .onChange(of: store.localFolders.map(\.id)) { _, _ in
            applyDefaultFocusIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLocalFolderFocus)) { _ in
            guard let sourceID = selection?.sourceID ?? focusedSourceID ?? store.localFolders.first?.id else { return }
            toggleFocus(sourceID: sourceID)
        }
    }

    private func applyDefaultFocusIfNeeded() {
        guard !hasAppliedDefaultFocus, let sourceID = store.localFolders.first?.id else { return }
        focusedSourceID = sourceID
        hasAppliedDefaultFocus = true
    }

    private func toggleFocus(sourceID: String) {
        focusedSourceID = focusedSourceID == sourceID ? nil : sourceID
    }
}

private struct LocalFolderSourceRow: View {
    @ObservedObject var store: AssetStore
    let folder: LocalFolderSource
    @Binding var selection: LocalFolderSelection?
    @Binding var focusedSourceID: String?
    @Binding var folderScope: LocalFolderScope
    let searchQuery: String
    let quickAccessItems: [SidebarQuickAccessItem]
    let onToggleQuickAccess: (SidebarQuickAccessItem) -> Void
    let onFolderRenamed: (String, String, String) -> Void
    let onSelect: (LocalFolderSelection) -> Void
    @State private var expandedPaths: Set<String>
    @State private var isRootDropTarget = false
    @State private var isRootExpanded = true

    init(
        store: AssetStore,
        folder: LocalFolderSource,
        selection: Binding<LocalFolderSelection?>,
        focusedSourceID: Binding<String?>,
        folderScope: Binding<LocalFolderScope>,
        searchQuery: String,
        quickAccessItems: [SidebarQuickAccessItem],
        onToggleQuickAccess: @escaping (SidebarQuickAccessItem) -> Void,
        onFolderRenamed: @escaping (String, String, String) -> Void,
        onSelect: @escaping (LocalFolderSelection) -> Void
    ) {
        self.store = store
        self.folder = folder
        _selection = selection
        _focusedSourceID = focusedSourceID
        _folderScope = folderScope
        self.searchQuery = searchQuery
        self.quickAccessItems = quickAccessItems
        self.onToggleQuickAccess = onToggleQuickAccess
        self.onFolderRenamed = onFolderRenamed
        self.onSelect = onSelect
        _expandedPaths = State(initialValue: LocalFolderTreeLayout.initialExpandedPaths(folder.directoryPaths))
    }

    private var rootSelection: LocalFolderSelection {
        LocalFolderSelection(sourceID: folder.id, relativePath: "")
    }

    private var isFocused: Bool {
        focusedSourceID == folder.id
    }

    private var showsChildren: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || focusedSourceID == nil || isFocused
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasRootChildren: Bool {
        LocalFolderTreeLayout.hasRootChildren(folder.directoryPaths)
    }

    private var visibleRows: [LocalFolderTreeRow] {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalFolderTreeLayout.searchRows(directoryPaths: folder.directoryPaths, query: searchQuery)
        }
        return LocalFolderTreeLayout.visibleRows(
            directoryPaths: folder.directoryPaths,
            expandedPaths: expandedPaths
        )
    }

    private var rootQuickAccessItem: SidebarQuickAccessItem {
        SidebarQuickAccessItem(projectID: store.currentProject.id, sourceID: folder.id, relativePath: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            folderLabel
            if showsChildren, isRootExpanded || isSearching {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleRows) { row in
                        LocalFolderNodeButton(
                            store: store,
                            folder: folder,
                            row: row,
                            expandedPaths: $expandedPaths,
                            selection: $selection,
                            folderScope: $folderScope,
                            quickAccessItems: quickAccessItems,
                            onToggleQuickAccess: onToggleQuickAccess,
                            onFolderRenamed: onFolderRenamed,
                            onSelect: onSelect
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .onChange(of: folder.directoryPaths) { oldPaths, newPaths in
            expandedPaths = LocalFolderTreeLayout.reconcileExpandedPaths(
                expandedPaths,
                oldDirectoryPaths: oldPaths,
                newDirectoryPaths: newPaths
            )
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            if hasRootChildren {
                Button(
                    isRootExpanded ? "收起\(folder.sidebarDisplayName)" : "展开\(folder.sidebarDisplayName)",
                    systemImage: isRootExpanded ? "chevron.down" : "chevron.right",
                    action: toggleRootExpansion
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2.weight(.semibold))
                .frame(width: 12)
                .accessibilityValue(isRootExpanded ? "已展开" : "已收起")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            Button(action: { onSelect(rootSelection) }) {
                HStack(spacing: 6) {
                    Image(systemName: isRootDropTarget ? "folder.fill.badge.plus" : (isRootExpanded ? "folder.fill" : "folder"))
                        .foregroundStyle(isRootDropTarget || selection == rootSelection ? Color.accentColor : Color.secondary)
                    Text(folder.sidebarDisplayName)
                        .lineLimit(1)
                    if isFocused {
                        Image(systemName: "list.bullet.indent")
                            .foregroundStyle(Color.accentColor)
                            .help("已进入层级浏览：只显示当前资料库，可逐层展开")
                    }
                    Spacer()
                    Text(store.localFolderAssetCount(folder.id, relativePath: ""), format: .number)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            isRootDropTarget ? Color.accentColor.opacity(0.24) :
                (selection == rootSelection ? Color.accentColor.opacity(0.13) : .clear),
            in: .rect(cornerRadius: 6)
        )
        .help(folder.rootPath)
        .onDrop(
            of: [AssetDragPasteboard.identifier],
            delegate: LocalFolderAssetDropDelegate(
                store: store,
                destination: rootSelection,
                isTargeted: $isRootDropTarget
            )
        )
        .contextMenu {
            Button(
                quickAccessItems.contains(rootQuickAccessItem) ? "从快速访问移除" : "添加到快速访问",
                systemImage: quickAccessItems.contains(rootQuickAccessItem) ? "pin.slash" : "pin",
                action: { onToggleQuickAccess(rootQuickAccessItem) }
            )
            Button(
                isFocused ? "退出层级浏览" : "进入层级浏览",
                systemImage: isFocused ? "arrow.uturn.backward" : "list.bullet.indent",
                action: toggleFocus
            )
            Divider()
            Menu("浏览范围", systemImage: "folder.badge.gearshape") {
                ForEach(LocalFolderScope.allCases) { scope in
                    Button {
                        folderScope = scope
                        onSelect(rootSelection)
                    } label: {
                        if folderScope == scope { Label(scope.rawValue, systemImage: "checkmark") }
                        else { Text(scope.rawValue) }
                    }
                }
            }
            Button("在 Finder 中打开", systemImage: "folder") {
                store.revealLocalFolder(folder.id)
            }
            Button("复制本地路径", systemImage: "doc.on.doc") {
                store.copyLocalFolderPath(folder.id)
            }
            Button("立即刷新", systemImage: "arrow.clockwise") {
                store.refreshLocalFolder(folder.id)
            }
            Button("重新定位文件夹…", systemImage: "arrow.triangle.2.circlepath") {
                store.relocateLocalFolder(folder.id)
            }
            Divider()
            Button("从资料库移除", systemImage: "minus.circle") {
                store.removeLocalFolder(folder.id)
                if selection?.sourceID == folder.id { selection = nil }
                if focusedSourceID == folder.id { focusedSourceID = nil }
            }
        }
    }

    private func toggleFocus() {
        onSelect(rootSelection)
        focusedSourceID = isFocused ? nil : folder.id
        isRootExpanded = true
    }

    private func toggleRootExpansion() {
        if !showsChildren {
            focusedSourceID = nil
            isRootExpanded = true
        } else {
            isRootExpanded.toggle()
        }
    }
}

private struct LocalFolderNodeButton: View {
    @ObservedObject var store: AssetStore
    let folder: LocalFolderSource
    let row: LocalFolderTreeRow
    @Binding var expandedPaths: Set<String>
    @Binding var selection: LocalFolderSelection?
    @Binding var folderScope: LocalFolderScope
    let quickAccessItems: [SidebarQuickAccessItem]
    let onToggleQuickAccess: (SidebarQuickAccessItem) -> Void
    let onFolderRenamed: (String, String, String) -> Void
    let onSelect: (LocalFolderSelection) -> Void
    @State private var renameDraft = ""
    @State private var isRenamePresented = false
    @State private var isDropTarget = false

    private var nodeSelection: LocalFolderSelection {
        LocalFolderSelection(sourceID: folder.id, relativePath: row.relativePath)
    }

    private var isExpanded: Bool {
        expandedPaths.contains(row.relativePath)
    }

    private var quickAccessItem: SidebarQuickAccessItem {
        SidebarQuickAccessItem(
            projectID: store.currentProject.id,
            sourceID: folder.id,
            relativePath: row.relativePath
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            if row.hasChildren {
                Button(
                    isExpanded ? "折叠\(row.name)" : "展开\(row.name)",
                    systemImage: isExpanded ? "chevron.down" : "chevron.right",
                    action: toggleExpansion
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2.weight(.semibold))
                .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Button {
                onSelect(nodeSelection)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isDropTarget ? "folder.fill.badge.plus" : (row.hasChildren && isExpanded ? "folder.fill" : "folder"))
                        .foregroundStyle(isDropTarget || selection == nodeSelection ? Color.accentColor : Color.secondary)
                    Text(row.name)
                        .lineLimit(1)
                        .foregroundStyle(selection == nodeSelection ? Color.primary : Color.secondary)
                    Spacer()
                    Text(store.localFolderAssetCount(folder.id, relativePath: row.relativePath), format: .number)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .font(.callout.weight(selection == nodeSelection ? .semibold : .regular))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .padding(.leading, 18 + CGFloat(row.depth) * 14)
        .background(
            isDropTarget ? Color.accentColor.opacity(0.24) :
                (selection == nodeSelection ? Color.accentColor.opacity(0.13) : .clear),
            in: .rect(cornerRadius: 6)
        )
        .onDrop(
            of: [AssetDragPasteboard.identifier],
            delegate: LocalFolderAssetDropDelegate(
                store: store,
                destination: nodeSelection,
                isTargeted: $isDropTarget
            )
        )
        .contextMenu {
            Button(
                quickAccessItems.contains(quickAccessItem) ? "从快速访问移除" : "添加到快速访问",
                systemImage: quickAccessItems.contains(quickAccessItem) ? "pin.slash" : "pin",
                action: { onToggleQuickAccess(quickAccessItem) }
            )
            Menu("浏览范围", systemImage: "folder.badge.gearshape") {
                ForEach(LocalFolderScope.allCases) { scope in
                    Button {
                        folderScope = scope
                        onSelect(nodeSelection)
                    } label: {
                        if folderScope == scope { Label(scope.rawValue, systemImage: "checkmark") }
                        else { Text(scope.rawValue) }
                    }
                }
            }
            Divider()
            Button("在 Finder 中打开", systemImage: "folder") {
                store.revealLocalFolder(folder.id, relativePath: row.relativePath)
            }
            Button("复制本地路径", systemImage: "doc.on.doc") {
                store.copyLocalFolderPath(folder.id, relativePath: row.relativePath)
            }
            Divider()
            Button("重命名文件夹…", systemImage: "pencil") {
                renameDraft = row.name
                isRenamePresented = true
            }
        }
        .alert("重命名文件夹", isPresented: $isRenamePresented) {
            TextField("文件夹名称", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("重命名", action: renameFolder)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("将直接修改 Finder 中的真实文件夹名称，并同步更新 App 内的照片路径。")
        }
    }

    private func toggleExpansion() {
        if isExpanded {
            expandedPaths.remove(row.relativePath)
        } else {
            expandedPaths.insert(row.relativePath)
        }
    }

    private func renameFolder() {
        let oldPath = row.relativePath
        guard let newPath = store.renameLocalFolder(folder.id, relativePath: oldPath, to: renameDraft) else { return }
        onFolderRenamed(folder.id, oldPath, newPath)
        expandedPaths = Set(expandedPaths.map { path in
            if path == oldPath { return newPath }
            guard path.hasPrefix(oldPath + "/") else { return path }
            return newPath + String(path.dropFirst(oldPath.count))
        })
        if selection == nodeSelection {
            let renamedSelection = LocalFolderSelection(sourceID: folder.id, relativePath: newPath)
            selection = renamedSelection
            onSelect(renamedSelection)
        }
    }
}
