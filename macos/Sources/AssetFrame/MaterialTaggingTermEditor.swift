import SwiftUI

struct MaterialTaggingTermEditor: View {
    let term: MaterialTaggingState.Term
    let terms: [MaterialTaggingState.Term]
    var issue: String? = nil
    var saving = false
    let onSave: (MaterialTaggingState.Term, String?) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var aliases = ""
    @State private var dimension = ""
    @State private var scope = "通用"
    @State private var favorite = false
    @State private var enabled = true
    @State private var mergeID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(term.name.isEmpty ? "新增词条" : "编辑词条").font(.title2)
            TextField("标准名称", text: $name)
            TextField("别名（逗号分隔）", text: $aliases)
            Picker("分类维度", selection: $dimension) {
                Text("自由标签").tag("")
                ForEach(ClassificationVocabulary.dimensions) { Text($0.name).tag($0.id) }
                if !dimension.isEmpty && ClassificationVocabulary.dimension(dimension) == nil { Text(dimension).tag(dimension) }
            }
            TextField("适用范围：通用或项目名称", text: $scope)
            Toggle("加入常用", isOn: $favorite)
            Toggle("启用，供后续整理使用", isOn: $enabled)
            if !term.name.isEmpty {
                Divider()
                Picker("合并到现有词条", selection: $mergeID) {
                    Text("不合并").tag("")
                    ForEach(terms.filter { $0.id != term.id && $0.dimension == dimension && $0.scope == scope }) { Text($0.name).tag($0.id) }
                }
                Text("改名与合并会更新已有标注，并可撤销。合并须使用相同维度与适用范围。停用不会移除已标注结果。").font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(mergeID.isEmpty ? "保存词条" : "保存并合并") {
                    var edited = term
                    edited.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    edited.dimension = dimension; edited.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
                    edited.aliases = aliases.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    edited.favorite = favorite; edited.enabled = enabled
                    onSave(edited, mergeID.isEmpty ? nil : mergeID)
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 560).textFieldStyle(.roundedBorder)
            .disabled(saving).interactiveDismissDisabled(saving)
            .task { name = term.name; aliases = term.aliases.joined(separator: "、"); dimension = term.dimension; scope = term.scope; favorite = term.favorite; enabled = term.enabled }
    }
}
