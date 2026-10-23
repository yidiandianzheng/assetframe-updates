import SwiftUI

struct ManjuSettingsView: View {
    @State private var connectionSettings = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.defaultValue.rawValue
    var body: some View {
        Form {
            Section("漫剧项目工作台") {
                Text("管理原项目中的 Markdown、分集、人物、造型及媒体引用。素材文件保留原位置。")
                Text("素材管理的文件夹、标签、收藏和素材整理在独立的「向量·素仓」App 中使用。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in Text(option.displayName).tag(option.rawValue) }
                }
            }
            Section("AI 资料整理") {
                Text("仅在项目开启自动整理后发送必要文字；原文不会被自动改写。")
                Button("连接设置…") { connectionSettings = true }
            }
        }.formStyle(.grouped).padding().frame(width: 600, height: 380)
        .sheet(isPresented: $connectionSettings) {
            DeepSeekSettingsView(task: .characterOrganization, startsAfterSave: false,
                usageDescription: "连接配置保存在向量·剧坊；项目分别控制是否开启自动整理。",
                onSave: { _ in connectionSettings = false }, onCancel: { connectionSettings = false })
        }
    }
}
