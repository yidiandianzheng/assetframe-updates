import SwiftUI

struct MaterialTaggingSourceEditor: View {
    let source: MaterialTaggingState.Source
    var issue: String? = nil
    var saving = false
    let onSave: (MaterialTaggingState.Source) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var scope = "通用"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("资料来源设置").font(.title2)
            TextField("显示名称（如：女儿和老爹穿越古代）", text: $name)
            TextField("适用范围", text: $scope)
            HStack {
                Text("常用范围").font(.caption).foregroundStyle(.secondary)
                ForEach(["通用", "古装短剧", "茶商业"], id: \.self) { value in Button(value) { scope = value } }
            }
            Text("可以填写自定义项目范围。范围用于关联文档中的词条选择；例如“古装短剧”允许使用对应的人物词，“茶商业”允许使用对应的产品词。系统不会仅凭目录名称认定图片身份。")
                .font(.caption).foregroundStyle(.secondary)
            Text(source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存来源") {
                    var edited = source
                    edited.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    edited.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(edited)
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 600).textFieldStyle(.roundedBorder)
            .disabled(saving).interactiveDismissDisabled(saving)
            .task { name = source.name; scope = source.scope ?? "通用" }
    }
}
