import SwiftUI

struct AssetFrameSettingsView: View {
    @ObservedObject var updateController: UpdateController
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralSettingsPane()
                .tabItem { Label(SettingsPane.general.displayName, systemImage: SettingsPane.general.systemImage) }
                .tag(SettingsPane.general)
            ShortcutsSettingsPane()
                .tabItem { Label(SettingsPane.shortcuts.displayName, systemImage: SettingsPane.shortcuts.systemImage) }
                .tag(SettingsPane.shortcuts)
            AIPrivacySettingsPane()
                .tabItem { Label(SettingsPane.aiPrivacy.displayName, systemImage: SettingsPane.aiPrivacy.systemImage) }
                .tag(SettingsPane.aiPrivacy)
            SoftwareUpdateSettingsPane(controller: updateController)
                .tabItem { Label(SettingsPane.update.displayName, systemImage: SettingsPane.update.systemImage) }
                .tag(SettingsPane.update)
        }
        .frame(width: 680, height: 560)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case aiPrivacy
    case update

    var id: Self { self }
    var displayName: String {
        switch self {
        case .general: "通用"
        case .shortcuts: "快捷键"
        case .aiPrivacy: "AI 与隐私"
        case .update: "软件更新"
        }
    }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .aiPrivacy: "lock.shield"
        case .update: "arrow.triangle.2.circlepath"
        }
    }
}

private struct GeneralSettingsPane: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.defaultValue.rawValue

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .defaultValue },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("外观", selection: appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.displayName, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(appearance.wrappedValue.detail).foregroundStyle(.secondary)
            }
            Section("资产规则") {
                Label("1–4 星只管理原文件位置，不复制原图", systemImage: "externaldrive")
                Label("首次评为 5 星时创建当前项目精选副本", systemImage: "star.fill")
                Label("加入通用资产时创建独立的跨项目复用副本", systemImage: "sparkles.rectangle.stack")
                Text("5 星代表当前项目质量判断；通用资产代表允许跨项目复用。两者互不替代。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            Section("全局快捷键") {
                LabeledContent("搜索当前页面", value: "⌘F")
                LabeledContent("导入图片", value: "⌘I")
                LabeledContent("预览所选", value: "Space")
                LabeledContent("切换侧栏", value: "⌥⌘S")
                LabeledContent("切换详情", value: "⌥⌘I")
                LabeledContent("评分", value: "⌃1…⌃5")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AIPrivacySettingsPane: View {
    @State private var showsTaggingSettings = false
    @State private var showsVisionSettings = false
    @State private var showsTextAISettings = false

    var body: some View {
        Form {
            Section("默认边界") {
                Label("AI 只提供名称、类型和标签建议", systemImage: "sparkles")
                Label("不会自动移动、删除、评星或锁定资产", systemImage: "hand.raised.fill")
                Label("API Key 只保存在 macOS Keychain", systemImage: "key.fill")
            }
            Section("在线服务") {
                Button("标签识别接口（独立）…", systemImage: "tag") { showsTaggingSettings = true }
                Button("视觉 API 设置…", systemImage: "eye") { showsVisionSettings = true }
                Button("文字 AI 设置…", systemImage: "text.bubble") { showsTextAISettings = true }
                Text("只有你在具体功能中确认发送，或在设置页主动测试连接时，才会发起网络请求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showsTaggingSettings) {
            MaterialTaggingAPISettingsView(onClose: { showsTaggingSettings = false })
        }
        .sheet(isPresented: $showsVisionSettings) {
            VisionAPISettingsView(
                onSave: { _ in showsVisionSettings = false },
                onCancel: { showsVisionSettings = false }
            )
        }
        .sheet(isPresented: $showsTextAISettings) {
            DeepSeekSettingsView(
                task: .pendingImport,
                startsAfterSave: false,
                onSave: { _ in showsTextAISettings = false },
                onCancel: { showsTextAISettings = false }
            )
        }
    }
}

private struct SoftwareUpdateSettingsPane: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        Form {
            Section("软件更新") {
                Toggle(
                    "每天自动检查更新",
                    isOn: Binding(
                        get: { controller.automaticallyChecksForUpdates },
                        set: { enabled in controller.setAutomaticallyChecksForUpdates(enabled) }
                    )
                )
                .disabled(!controller.isConfigured)
                Button("立即检查更新", action: controller.checkForUpdates)
                    .disabled(!controller.isConfigured || !controller.canCheckForUpdates)
                if !controller.isConfigured {
                    Label("当前安装包尚未配置在线更新源", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            Section("版本") {
                LabeledContent("当前版本", value: AppVersion.annotatedDisplay)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
