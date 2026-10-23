import SwiftUI

struct DeepSeekSettingsView: View {
    let task: DeepSeekTaskKind
    let startsAfterSave: Bool
    let usageDescription: String
    let onSave: (DeepSeekConfiguration) -> Void
    let onCancel: () -> Void

    @State private var baseURL: String
    @State private var fastModel: String
    @State private var deepModel: String
    @State private var apiKey: String
    @State private var errorMessage: String?

    init(
        task: DeepSeekTaskKind,
        startsAfterSave: Bool,
        usageDescription: String = "DeepSeek 只处理文字和结构化数据，不会上传或生成图片。",
        onSave: @escaping (DeepSeekConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let draft = DeepSeekAPISettings.draftSettings()
        self.task = task
        self.startsAfterSave = startsAfterSave
        self.usageDescription = usageDescription
        self.onSave = onSave
        self.onCancel = onCancel
        _baseURL = State(initialValue: draft.baseURL)
        _fastModel = State(initialValue: draft.fastModel)
        _deepModel = State(initialValue: draft.deepModel)
        _apiKey = State(initialValue: draft.apiKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("DeepSeek 资产助理", systemImage: "sparkles")
                    .font(.title2)
                    .bold()
                Spacer()
                Text("全局连接设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                Text("配置保存后持续复用。已开启自动整理的项目会在软件打开期间处理必要文字，其余任务由你启动。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("API 地址", text: $baseURL)
                TextField("快速整理模型", text: $fastModel)
                TextField("深度分析模型", text: $deepModel)
                SecureField("API Key", text: $apiKey)
            }
            .formStyle(.grouped)

            Label(usageDescription, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(startsAfterSave ? "保存并启动" : "保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func save() {
        let draft = DeepSeekSettingsDraft(
            baseURL: baseURL,
            fastModel: fastModel,
            deepModel: deepModel,
            apiKey: apiKey
        )
        do {
            try DeepSeekAPISettings.save(draft)
            onSave(draft.configuration(for: task))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
