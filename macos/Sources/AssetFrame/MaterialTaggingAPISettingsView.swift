import SwiftUI

struct MaterialTaggingAPISettingsView: View {
    let onClose: () -> Void
    @State private var draft = MaterialTaggingAPISettings.Draft()
    @State private var issue: String?
    @State private var busy = false
    @State private var confirmTest = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("标签识别 · 独立 AI 接口", systemImage: "network").font(.title2.bold())
            Text("填写你以后选用的外部服务。未配置时，本机整理和人工确认仍可使用。")
                .foregroundStyle(.secondary)
            Form {
                TextField("接口地址", text: $draft.baseURL, prompt: Text("https://你的服务地址/v1"))
                TextField("模型名称", text: $draft.model)
                SecureField("API Key", text: $draft.apiKey)
                TextField("超时（秒）", value: $draft.timeout, format: .number)
            }.textFieldStyle(.roundedBorder).disabled(busy)
            Text("当前支持兼容 Chat Completions 的服务；其他接口格式需要对应适配。此配置独立于编程助手及其他 AI 功能，密钥仅保存在本机钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if busy { ProgressView("正在测试指定接口…") }
            HStack {
                Button("测试看图连接…") { confirmTest = true }.disabled(busy || !draft.isComplete)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction).disabled(busy)
                Button("保存配置") { save() }.buttonStyle(.borderedProminent).disabled(busy || !draft.isComplete)
            }
            Text("保存配置不发送请求。测试连接将发送一张内置红蓝测试图；实际图片仅在你选中并确认发送后上传。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 640)
            .task { draft = MaterialTaggingAPISettings.draft() }
            .onDisappear { task?.cancel() }
            .interactiveDismissDisabled(busy)
            .alert("发送内置测试图？", isPresented: $confirmTest) {
                Button("取消", role: .cancel) { }
                Button("发送并测试") { test() }
            } message: {
                Text("接口：\(draft.baseURL)\n模型：\(draft.model)\n仅发送内置红蓝测试图，可能产生该服务的 API 费用。")
            }
    }
    private func save() {
        do { try MaterialTaggingAPISettings.save(draft); onClose() }
        catch { issue = error.localizedDescription }
    }
    private func test() {
        let value = draft
        busy = true; issue = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let config = VisionAPIConfiguration(baseURL: value.baseURL, model: value.model, apiKey: value.apiKey, timeoutSeconds: value.timeout, batchSize: 1)
                try await OpenAICompatibleVisionClient().testConnection(configuration: config)
                try Task.checkCancellation()
                try MaterialTaggingAPISettings.save(value)
                MaterialTaggingAPISettings.recordVisionVerification(value)
                issue = "测试通过，已保存独立接口配置。"
            } catch { issue = error.localizedDescription }
        }
    }
}
