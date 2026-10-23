import SwiftUI

/// 单选素材的分类编辑器：受控词表取值，备注保持独立；点击即时保存并进入整理历史。
struct MaterialClassificationEditor: View {
    @ObservedObject var store: GlobalMaterialStore
    let material: MaterialRecord
    @State private var expanded = false
    @State private var showTagging = false

    private var classification: MaterialClassification { material.classification ?? MaterialClassification() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if AppProduct.current == .assets {
                Button("标签与分类…", systemImage: "tag") { showTagging = true }
                    .help("本机整理、候选确认、标签管理及图文资料关联")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(classification.isEmpty ? "未分类" : classification.displayText)
                    .font(.caption)
                    .foregroundStyle(classification.isEmpty ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !classification.isEmpty {
                    Button("清除") {
                        store.update(material.id) { $0.classification = nil }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("清除该素材的全部分类词")
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(ClassificationVocabulary.dimensions) { dimension in
                        dimensionRow(dimension)
                    }
                    Text("分类使用本库词表；可在“标签与分类”中添加自定义词、收藏常用词。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Label("快速编辑分类", systemImage: "square.grid.2x2")
                    .font(.caption)
            }
        }
        .sheet(isPresented: $showTagging) {
            MaterialTaggingWorkspace(store: store, scopeIDs: [material.id], selectedIDs: [material.id]) { showTagging = false }
        }
    }

    @ViewBuilder private func dimensionRow(_ dimension: ClassificationDimension) -> some View {
        let selected = classification.terms(for: dimension.id)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(dimension.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
                .help(dimension.summary)
            Menu {
                Button("清除该维度") {
                    update { $0.clear(dimension.id) }
                }
                .disabled(selected.isEmpty)
                Divider()
                ForEach(store.tagging.effectiveTerms.filter { $0.dimension == dimension.id && ($0.enabled || selected.contains($0.name)) }) { term in
                    Button {
                        update { $0.toggle(term.name, in: term.dimension) }
                    } label: {
                        if selected.contains(term.name) { Label(term.name + (term.enabled ? "" : "（已停用）"), systemImage: "checkmark") }
                        else { Text(term.name) }
                    }
                }
                ForEach(selected.filter { name in !store.tagging.effectiveTerms.contains { $0.name == name && $0.dimension == dimension.id } }, id: \.self) { name in
                    Button("移除：" + name) { update { $0.remove(name, in: dimension.id) } }
                }
            } label: {
                Text(selected.isEmpty ? "未设置" : selected.joined(separator: " / "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected.isEmpty ? Color.secondary : Color.primary)
            }
            .menuStyle(.borderlessButton)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func termButton(_ term: ClassificationTerm, isSelected: Bool) -> some View {
        Button {
            update { $0.toggle(term.canonical, in: term.dimension) }
        } label: {
            if isSelected {
                Label(term.canonical, systemImage: "checkmark")
            } else {
                Text(term.canonical)
            }
        }
        .help(term.helpText)
    }

    private func update(_ transform: @escaping (inout MaterialClassification) -> Void) {
        store.update(material.id) { record in record.mutateClassification(transform) }
    }

    private func termGroups(_ dimension: ClassificationDimension) -> [ClassificationTermGroup] {
        let terms = ClassificationVocabulary.terms(in: dimension.id)
        if dimension.id == "asset_type" || dimension.id == "usage" || dimension.id == "quality" || dimension.id == "style" || dimension.id == "negative" {
            return [ClassificationTermGroup(title: "", terms: terms)]
        }
        var groups: [ClassificationTermGroup] = []
        for status in ["推荐", "候选"] {
            let matching = terms.filter { $0.status == status }
            if !matching.isEmpty { groups.append(ClassificationTermGroup(title: status == "推荐" ? "推荐" : "候选", terms: matching)) }
        }
        return groups
    }
}

private struct ClassificationTermGroup: Identifiable {
    var title: String
    var terms: [ClassificationTerm]
    var id: String { title + terms.map(\.id).joined(separator: ",") }
}

private extension ClassificationTerm {
    var helpText: String {
        let counts = "提示词 \(promptDocFreq) 份" + (fileEvidence > 0 ? " · 文件名 \(fileEvidence) 条" : "")
        return "\(status) · \(counts)" + (note.isEmpty ? "" : " · \(note)")
    }
}

/// 多选素材的批量分类菜单：写入同一个受控字段，不触碰备注与文件名。
struct MaterialBatchClassificationMenu: View {
    @ObservedObject var store: GlobalMaterialStore
    let ids: Set<String>
    @State private var showTagging = false

    var body: some View {
        Group {
        if AppProduct.current == .assets {
            Button("标签与分类…", systemImage: "tag") { showTagging = true }
        } else {
        Menu("批量分类", systemImage: "square.grid.2x2") {
            Button("清除全部分类") {
                store.batchUpdate(ids) { $0.classification = nil }
                store.toast = "已清除 \(ids.count) 项素材的分类"
            }
            Divider()
            ForEach(ClassificationVocabulary.dimensions) { dimension in
                Menu(dimension.name) {
                    ForEach(ClassificationVocabulary.terms(in: dimension.id)) { term in
                        Button(term.canonical) { apply(term) }
                    }
                    Divider()
                    Button("清除该维度") {
                        store.batchUpdate(ids) { $0.mutateClassification { $0.clear(dimension.id) } }
                        store.toast = "已清除 \(ids.count) 项素材的\(dimension.name)分类"
                    }
                }
            }
        }
        }
        }
        .disabled(ids.isEmpty || !store.canWrite)
        .help("把受控分类批量写入已选素材；备注不受影响")
        .sheet(isPresented: $showTagging) {
            MaterialTaggingWorkspace(store: store, scopeIDs: ids, selectedIDs: ids) { showTagging = false }
        }
    }

    private func apply(_ term: ClassificationTerm) {
        store.batchUpdate(ids) { record in
            record.mutateClassification { value in
                if ClassificationVocabulary.allowsMultiple(term.dimension) {
                    value.add(term.canonical, in: term.dimension)
                } else {
                    value.set([term.canonical], for: term.dimension)
                }
            }
        }
        store.toast = "已将 \(ids.count) 项素材设为「\(term.canonical)」"
    }
}
