import SwiftUI

struct VisionAPISettingsView: View {
    let onSave: (VisionAPIConfiguration) -> Void
    let onCancel: () -> Void

    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String
    @State private var timeoutSeconds: Double
    @State private var batchSize: Int
    @State private var isTesting = false
    @State private var errorMessage: String?

    init(
        onSave: @escaping (VisionAPIConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let configuration = VisionAPISettings.draftConfiguration()
        self.onSave = onSave
        self.onCancel = onCancel
        _baseURL = State(initialValue: configuration.baseURL)
        _model = State(initialValue: configuration.model)
        _apiKey = State(initialValue: configuration.apiKey)
        _timeoutSeconds = State(initialValue: configuration.timeoutSeconds)
        _batchSize = State(initialValue: configuration.batchSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("图片识别 API", systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.title2)
                    .bold()
                Text("使用 OpenAI-compatible /chat/completions，多模态图片通过 image_url Base64 Data URL 发送。")
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("接口") {
                    TextField("Base URL", text: $baseURL)
                    TextField("视觉模型名称", text: $model)
                    SecureField("API Key", text: $apiKey)
                }
                Section("请求控制") {
                    LabeledContent("超时时间") {
                        TextField("秒", value: $timeoutSeconds, format: .number)
                            .frame(width: 100)
                        Text("秒")
                    }
                    Stepper("同时分析 \(batchSize) 张", value: $batchSize, in: 1...8)
                }
            }
            .formStyle(.grouped)

            Label("测试会发送一张内置红蓝测试图，可能产生 API 费用；用于当前视觉功能。正式分析只发送最长边 1280px 的 JPEG 预览，不发送绝对路径或原图。API Key 仅保存到 macOS Keychain。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isTesting ? "正在验证看图能力…" : "测试连接并保存", action: testAndSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTesting)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func testAndSave() {
        let configuration = VisionAPIConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            timeoutSeconds: timeoutSeconds,
            batchSize: batchSize
        )
        guard configuration.isComplete else {
            errorMessage = "请填写有效的 API 地址、视觉模型名称、API Key、超时时间和并发数量"
            return
        }
        isTesting = true
        errorMessage = nil
        Task {
            do {
                try await OpenAICompatibleVisionClient().testConnection(configuration: configuration)
                try VisionAPISettings.save(configuration)
                isTesting = false
                onSave(configuration)
            } catch {
                isTesting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
