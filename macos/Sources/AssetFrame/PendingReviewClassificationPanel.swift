import SwiftUI

struct PendingReviewClassificationPanel: View {
    let item: PendingImportItem
    let generationBatch: GenerationBatchRecord?
    let availableTags: [String]
    let onNameChange: (String) -> Void
    let onTypeChange: (AssetType) -> Void
    let onCategoryChange: (AssetCategory) -> Void
    let onTagsChange: ([String]) -> Void
    @State private var selectedType: AssetType
    @State private var selectedCategory: AssetCategory
    @State private var tags: [String]
    @State private var tagDraft = ""

    init(
        item: PendingImportItem,
        generationBatch: GenerationBatchRecord?,
        availableTags: [String],
        onNameChange: @escaping (String) -> Void,
        onTypeChange: @escaping (AssetType) -> Void,
        onCategoryChange: @escaping (AssetCategory) -> Void,
        onTagsChange: @escaping ([String]) -> Void
    ) {
        self.item = item
        self.generationBatch = generationBatch
        self.availableTags = availableTags
        self.onNameChange = onNameChange
        self.onTypeChange = onTypeChange
        self.onCategoryChange = onCategoryChange
        self.onTagsChange = onTagsChange
        _selectedType = State(initialValue: item.suggestedType)
        _selectedCategory = State(initialValue: item.category)
        _tags = State(initialValue: item.normalizedManualTags)
    }

    var body: some View {
        Form {
            Section("图片信息") {
                PendingImportNameEditor(
                    itemID: item.id,
                    currentName: item.name,
                    onSave: onNameChange
                )
                LabeledContent("文件名") {
                    Text(item.originalFilename)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("清晰度", value: "\(item.resolutionLabel) · \(item.dimensionText)")
                LabeledContent("原图位置") {
                    Text(item.originalSourcePath)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if let provenance = item.generationProvenance {
                Section("Codex 生成谱系") {
                    GenerationProvenanceDetailsView(
                        provenance: provenance,
                        batch: generationBatch
                    )
                }
            }

            Section("资产分类") {
                Picker("资产类型", selection: $selectedType) {
                    ForEach(AssetType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                Picker("资产归类", selection: $selectedCategory) {
                    ForEach(AssetCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
            }

            Section("自定义标签") {
                if tags.isEmpty {
                    Text("可用标签记录模特风格、脸型、服装或用途")
                        .foregroundStyle(.secondary)
                } else {
                    FlowTagList(tags: tags, onRemove: removeTag)
                }
                TextField("输入标签，回车添加", text: $tagDraft)
                    .onSubmit(addDraftTags)
                if !availableTags.isEmpty {
                    Menu("添加已有标签", systemImage: "tag") {
                        ForEach(availableTags.filter { !tags.contains($0) }, id: \.self) { tag in
                            Button(tag) { addTag(tag) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedType) { _, newValue in onTypeChange(newValue) }
        .onChange(of: selectedCategory) { _, newValue in onCategoryChange(newValue) }
    }

    private func addDraftTags() {
        let values = tagDraft
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return }
        tags = Array(Set(tags + values)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        tagDraft = ""
        onTagsChange(tags)
    }

    private func addTag(_ tag: String) {
        guard !tags.contains(tag) else { return }
        tags.append(tag)
        tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        onTagsChange(tags)
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        onTagsChange(tags)
    }
}
