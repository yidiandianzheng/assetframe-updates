import SwiftUI

struct MaterialTaggingProposalCard: View {
    let proposal: MaterialTaggingState.Proposal
    let material: MaterialRecord?
    let selected: Bool
    let disabled: Bool
    let select: () -> Void
    let edit: () -> Void
    let ignore: () -> Void
    let accept: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                if let material {
                    MaterialThumbnailView(material: material).frame(width: 130, height: 105).clipped()
                    Button("预览") { MaterialQuickLookController.shared.show(material) }
                } else { Image(systemName: "photo").frame(width: 130, height: 105) }
                if proposal.status == "待确认" {
                    Button(selected ? "取消选择" : "选择", systemImage: selected ? "checkmark.circle.fill" : "circle", action: select)
                        .disabled(disabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(material?.name ?? proposal.materialID).font(.headline)
                    Spacer()
                    Label(proposal.status, systemImage: proposal.status == "已确认" ? "checkmark.circle" : "tag")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(proposal.engine).font(.caption).foregroundStyle(.secondary)
                }
                Text("已有标签：" + (material?.tags.joined(separator: "、").nilIfEmpty ?? "无")).font(.caption).foregroundStyle(.secondary)
                Text("已有分类：" + (material?.classificationDisplayText.nilIfEmpty ?? "无")).font(.caption).foregroundStyle(.secondary)
                Text("建议新增：" + (proposal.tags.joined(separator: "、").nilIfEmpty ?? "无"))
                if !proposal.removeTags.isEmpty { Label("建议移除：" + proposal.removeTags.joined(separator: "、"), systemImage: "minus.circle").foregroundStyle(.orange) }
                if !proposal.categories.isEmpty { Text("建议分类：" + proposal.categories.displayText) }
                if let removed = proposal.removeCategories, !removed.isEmpty {
                    Label("建议移除分类：" + removed.displayText, systemImage: "minus.circle").foregroundStyle(.orange)
                }
                if proposal.hasConflict { Label("存在冲突，请逐项核对现有内容与建议后确认", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                if proposal.missingDocuments { Label("缺少明确资料；可在“资料来源”绑定文档", systemImage: "doc.badge.ellipsis").font(.caption).foregroundStyle(.secondary) }
                if !proposal.error.isEmpty {
                    Text((proposal.status == "待确认" ? "部分识别：" : "处理失败：") + proposal.error).font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(proposal.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                    Text("待核对：" + uncertainty).font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("查看依据 · \(proposal.evidence.count) 条") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { _, evidence in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(evidence.kind).font(.caption.weight(.semibold))
                                if !evidence.path.isEmpty { Text(evidence.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                                if !evidence.excerpt.isEmpty { Text(evidence.excerpt).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }.padding(.top, 6)
                }.font(.caption)
                if proposal.status == "待确认" {
                    HStack {
                        Button("编辑候选", action: edit)
                        Button("忽略", action: ignore)
                        Spacer()
                        Button(needsConflictConfirmation ? "核对冲突后确认…" : "确认此项", action: accept)
                    }.disabled(disabled || material == nil)
                }
            }.font(.callout).textSelection(.enabled)
        }.padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
    }
    private var needsConflictConfirmation: Bool {
        proposal.hasConflict || !proposal.removeTags.isEmpty || (material.map { MaterialTaggingState.conflicts(proposal, with: $0) } ?? false)
    }
}

/// Draft copy preserves all source stamps. Saving only changes the proposed fields.
struct MaterialTaggingProposalEditor: View {
    let proposal: MaterialTaggingState.Proposal
    var material: MaterialRecord? = nil
    var issue: String? = nil
    var saving = false
    let onSave: (MaterialTaggingState.Proposal) -> Void
    let onCancel: () -> Void
    @State private var added = ""
    @State private var removed = ""
    @State private var dimensions: [String: String] = [:]
    @State private var removedDimensions: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("编辑候选").font(.title2)
            Text("修改只保存在候选中，确认后才写入图片。来源与版本依据保持原记录。").font(.caption).foregroundStyle(.secondary)
            TextField("建议新增标签（逗号分隔）", text: $added, axis: .vertical).lineLimit(2...4)
            TextField("建议移除现有标签（逗号分隔）", text: $removed, axis: .vertical).lineLimit(2...4)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(dimensionIDs, id: \.self) { dimension in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ClassificationVocabulary.dimension(dimension)?.name ?? dimension).font(.headline)
                            Text("已有：" + ((material?.classification?.terms(for: dimension) ?? []).joined(separator: "、").nilIfEmpty ?? "无"))
                                .font(.caption).foregroundStyle(.secondary)
                            LabeledContent("建议新增") {
                                TextField("逗号分隔；留空不新增", text: dimensionBinding(dimension))
                            }
                            LabeledContent("建议移除") {
                                TextField("填写已有的错误分类；留空不移除", text: removedDimensionBinding(dimension))
                            }
                            Divider()
                        }
                    }
                }
            }
            Text("建议新增与建议移除分别保存。移除已有分类、替换单选分类或删除标签，会在确认时明确提示。").font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存候选") {
                    var edited = proposal
                    edited.tags = split(added); edited.removeTags = split(removed)
                    edited.categories = .init(values: dimensions.mapValues(split))
                    let removal = MaterialClassification(values: removedDimensions.mapValues(split))
                    edited.removeCategories = removal.isEmpty ? nil : removal
                    if let material { edited.hasConflict = MaterialTaggingState.conflicts(edited, with: material) }
                    else { edited.hasConflict = edited.hasConflict || !edited.removeTags.isEmpty || !removal.isEmpty }
                    onSave(edited)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 680, height: 610).textFieldStyle(.roundedBorder)
            .disabled(saving).interactiveDismissDisabled(saving)
            .task {
                added = proposal.tags.joined(separator: "、"); removed = proposal.removeTags.joined(separator: "、")
                dimensions = proposal.categories.values.mapValues { $0.joined(separator: "、") }
                removedDimensions = (proposal.removeCategories?.values ?? [:]).mapValues { $0.joined(separator: "、") }
            }
    }
    private var dimensionIDs: [String] {
        let existing = Set(proposal.categories.values.keys).union(proposal.removeCategories?.values.keys.map { $0 } ?? [])
            .union(material?.classification?.values.keys.map { $0 } ?? [])
        return ClassificationVocabulary.dimensions.map(\.id) + existing.filter { ClassificationVocabulary.dimension($0) == nil }.sorted()
    }
    private func dimensionBinding(_ id: String) -> Binding<String> { Binding(get: { dimensions[id] ?? "" }, set: { dimensions[id] = $0 }) }
    private func removedDimensionBinding(_ id: String) -> Binding<String> { Binding(get: { removedDimensions[id] ?? "" }, set: { removedDimensions[id] = $0 }) }
    private func split(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
