import SwiftUI

struct PendingImportNameEditor: View {
    let itemID: String
    let currentName: String
    let onSave: (String) -> Void

    @State private var draftName: String

    init(itemID: String, currentName: String, onSave: @escaping (String) -> Void) {
        self.itemID = itemID
        self.currentName = currentName
        self.onSave = onSave
        _draftName = State(initialValue: currentName)
    }

    var body: some View {
        LabeledContent("规范名称") {
            HStack {
                TextField("例如：桑枝｜基础｜角色设定图", text: $draftName)
                    .onSubmit(save)
                Button("保存规范名称", systemImage: "checkmark", action: save)
                    .labelStyle(.iconOnly)
                    .disabled(!canSave)
                    .help("保存软件内名称；不会重命名原始生成文件")
            }
        }
        .onChange(of: itemID) { _, _ in
            draftName = currentName
        }
        .onChange(of: currentName) { _, newName in
            draftName = newName
        }
    }

    private var canSave: Bool {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines) != currentName
    }

    private func save() {
        guard canSave else { return }
        onSave(draftName)
    }
}
