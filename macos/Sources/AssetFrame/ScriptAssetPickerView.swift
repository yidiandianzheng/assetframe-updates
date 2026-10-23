import AppKit
import SwiftUI

struct ScriptVariantPickerSheet: View {
    @ObservedObject var store: AssetStore
    let extractionID: String
    let candidateID: String

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var scope: ScriptAssetSearchScope = .recommended
    @State private var sortMode: ScriptAssetMatchSortMode = .nameFirst
    @State private var matches: [ScriptAssetMatch] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isMatching = false
    @State private var referenceFeaturePrint: Data?

    private var candidate: ScriptAssetCandidate? {
        store.scriptExtractions.first(where: { $0.id == extractionID })?
            .candidates.first(where: { $0.id == candidateID })
    }

    private var matchFingerprint: String {
        [
            search, scope.rawValue, sortMode.rawValue, candidate?.name ?? "", candidate?.effectiveFormName ?? "",
            String(store.contentRevision), String(store.projectImageIndexRevision),
            referenceFeaturePrint == nil ? "no-reference" : "has-reference"
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchToolbar
            indexStatus
            Divider()
            resultsContent
            Divider()
            footer
        }
        .frame(minWidth: 980, idealWidth: 1120, minHeight: 650, idealHeight: 760)
        .task(id: matchFingerprint) { await refreshMatches() }
        .task(id: referenceSourcePath) { await loadReferenceFeaturePrint() }
        .onAppear {
            if store.projectImageIndex.isEmpty && !store.isProjectImageIndexing {
                store.refreshProjectImageIndex()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 25))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("智能匹配资产")
                    .font(.title2.bold())
                if let candidate {
                    Text("\(candidate.type.rawValue) · \(candidate.name) · \(candidate.effectiveFormName)")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("当前项目 \(store.projectImageIndex.count) 张原图")
                Text("本机识图 \(store.recognizedProjectImageCount) 张")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Button("关闭", action: dismiss.callAsFunction)
        }
        .padding(18)
    }

    private var searchToolbar: some View {
        HStack(spacing: 12) {
            Picker("搜索范围", selection: $scope) {
                ForEach(ScriptAssetSearchScope.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 430)

            Picker("排序", selection: $sortMode) {
                ForEach(ScriptAssetMatchSortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 155)

            TextField("搜索名称、形态、文件名、文件夹或调用编号", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280, maxWidth: .infinity)

            Button("重新索引", systemImage: "arrow.clockwise") {
                store.refreshProjectImageIndex()
            }
            .disabled(store.isProjectImageIndexing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var indexStatus: some View {
        if let progress = store.projectImageIndexProgress,
           progress.phase == .scanning || progress.phase == .recognizing {
            HStack(spacing: 10) {
                ProgressView(value: progress.total > 0 ? progress.fraction : nil)
                    .progressViewStyle(.linear)
                    .frame(width: 150)
                Text(progress.message)
                    .foregroundStyle(.secondary)
                Spacer()
                if progress.total > 0 { Text("\(progress.processed) / \(progress.total)").monospacedDigit() }
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.06))
        }
    }

    @ViewBuilder private var resultsContent: some View {
        if isMatching && matches.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在匹配项目资产…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matches.isEmpty {
            ContentUnavailableView(
                search.isEmpty ? emptyTitle : "没有匹配结果",
                systemImage: scope == .project ? "folder.badge.questionmark" : "photo.badge.checkmark",
                description: Text(emptyDescription)
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 310), spacing: 14)], spacing: 14) {
                    ForEach(matches) { match in
                        matchCard(match)
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("当前没有合适图片，标记待补图", systemImage: "photo.badge.exclamationmark") {
                store.markScriptCandidateMissing(extractionID: extractionID, candidateID: candidateID)
                dismiss()
            }
            Spacer()
            Text(selectedIDs.isEmpty
                 ? "只有已锁定形态会直接绑定；其他图片需你点击快速采用"
                 : "已选 \(selectedIDs.count) 张 · 第一张作为主图，最多两张作为补图")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !selectedIDs.isEmpty {
                Button("取消选择") { selectedIDs.removeAll() }
                Button("快速采用并绑定", systemImage: "checkmark.seal.fill", action: adoptSelection)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private func matchCard(_ match: ScriptAssetMatch) -> some View {
        let selected = selectedIDs.contains(match.id)
        let selectable = !match.source.isLocked && !isDraft(match.source)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if selectable { toggle(match.id) }
            } label: {
                ZStack(alignment: .topLeading) {
                    AssetPreviewThumbnail(
                        asset: match.previewAsset,
                        size: CGSize(width: 244, height: 146),
                        contentMode: .fit,
                        isEnabled: canPreview(match.source)
                    )
                    .frame(maxWidth: .infinity)
                    if selectable {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .padding(8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .accessibilityHint(selectable ? "轻点选择该匹配" : "当前不可选择")
            .help(selectable ? "选择匹配" : "当前不可选择")

            HStack(spacing: 7) {
                Text(match.source.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(match.source.isLocked ? Color.green : Color.accentColor)
                Spacer()
                Text("\(min(99, max(1, match.score)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(match.title).font(.headline).lineLimit(1)
            Text(match.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(match.pathText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                ForEach(match.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
            }
            .frame(minHeight: 22, alignment: .leading)
            cardAction(match)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 1)
        }
    }

    @ViewBuilder private func cardAction(_ match: ScriptAssetMatch) -> some View {
        switch match.source {
        case .lockedVariant(let variantID):
            Button("绑定此正式资产", systemImage: "link") {
                store.linkScriptCandidate(extractionID: extractionID, candidateID: candidateID, variantID: variantID)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case let .draftVariant(variantID, preferredMainID):
            Button("以此为主图，锁定并绑定", systemImage: "checkmark.seal") {
                store.quickLockAndBindVariant(
                    variantID: variantID, preferredMainID: preferredMainID,
                    extractionID: extractionID, candidateID: candidateID
                )
                dismiss()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .libraryAsset, .projectFile:
            HStack {
                if case .projectFile(_, let path) = match.source {
                    Button("在 Finder 中显示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(selectedIDs.contains(match.id) ? "已选择" : "选择此图", systemImage: selectedIDs.contains(match.id) ? "checkmark.circle.fill" : "plus.circle") {
                    toggle(match.id)
                }
            }
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .recommended: "暂无智能推荐"
        case .locked: "没有已锁定正式资产"
        case .library: "资产库没有可匹配图片"
        case .project: "当前项目没有可索引图片"
        }
    }

    private var emptyDescription: String {
        if !search.isEmpty { return "请尝试缩短搜索词，或切换到其他搜索范围" }
        if store.isProjectImageIndexing { return "项目图片正在后台索引，已发现的图片会逐步出现" }
        return "可以点击“重新索引”读取当前项目文件夹"
    }

    private func refreshMatches() async {
        guard let candidate else { matches = []; return }
        isMatching = true
        let assets = store.assets
        let variants = store.assetStacks
        let entities = store.assetEntities
        let projectImages = store.projectImageIndex
        let projectID = store.currentProject.id
        let projectName = store.currentProject.name
        let currentScope = scope
        let currentSortMode = sortMode
        let currentSearch = search
        let currentReferenceFeaturePrint = referenceFeaturePrint
        let output = await Task.detached(priority: .userInitiated) {
            ScriptAssetMatcher.matches(
                candidate: candidate, scope: currentScope, sortMode: currentSortMode, search: currentSearch,
                projectID: projectID, projectName: projectName, assets: assets,
                variants: variants, entities: entities, projectImages: projectImages,
                referenceFeaturePrint: currentReferenceFeaturePrint
            )
        }.value
        guard !Task.isCancelled else { return }
        matches = output
        selectedIDs.formIntersection(Set(output.map(\.id)))
        isMatching = false
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    private func adoptSelection() {
        let sources = matches.compactMap { match -> ScriptAssetDropSource? in
            guard selectedIDs.contains(match.id) else { return nil }
            switch match.source {
            case .libraryAsset(let assetID):
                return .libraryAsset(projectID: store.currentProject.id, assetID: assetID)
            case .projectFile(_, let path):
                return .fileURL(URL(fileURLWithPath: path))
            case .lockedVariant, .draftVariant:
                return nil
            }
        }
        store.quickAdoptScriptSources(sources, extractionID: extractionID, candidateID: candidateID)
        dismiss()
    }

    private func isDraft(_ source: ScriptAssetMatchSource) -> Bool {
        if case .draftVariant = source { return true }
        return false
    }

    private func canPreview(_ source: ScriptAssetMatchSource) -> Bool {
        if case .projectFile = source { return false }
        return true
    }

    private var referenceSourcePath: String {
        guard let candidate else { return "" }
        if let variant = store.assetStacks.first(where: { variant in
            guard let entity = store.entity(for: variant) else { return false }
            return entity.name.localizedCaseInsensitiveCompare(candidate.name) == .orderedSame &&
                AssetStore.scriptAssetType(candidate.type, matches: entity.type)
        }), let assetID = variant.mainAssetID ?? Optional(variant.coverAssetID),
           let asset = store.asset(withID: assetID) {
            return asset.imagePath
        }
        return store.assets.first(where: {
            $0.deletedAt == nil &&
            AssetStore.scriptAssetType(candidate.type, matches: $0.type) &&
            $0.name.localizedCaseInsensitiveContains(candidate.name)
        })?.imagePath ?? ""
    }

    private func loadReferenceFeaturePrint() async {
        let path = referenceSourcePath
        guard !path.isEmpty else { referenceFeaturePrint = nil; return }
        let data = await Task.detached(priority: .utility) {
            ProjectImageIndexer.featurePrintData(atPath: path)
        }.value
        guard !Task.isCancelled, path == referenceSourcePath else { return }
        referenceFeaturePrint = data
    }
}
