import Sparkle
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isConfigured = OnlineServiceConfiguration.isSparkleConfigured

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        if isConfigured {
            updaterController.startUpdater()
            canCheckForUpdates = updaterController.updater.canCheckForUpdates
            automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        updaterController.updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        Button("检查更新…", action: controller.checkForUpdates)
            .disabled(!controller.isConfigured || !controller.canCheckForUpdates)
    }
}

struct OnlineServicesSettingsView: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        Form {

            Section("软件更新") {
                Toggle(
                    "每天自动检查更新",
                    isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { enabled in updateController.setAutomaticallyChecksForUpdates(enabled) }
                    )
                )
                .disabled(!updateController.isConfigured)

                Button("立即检查更新", action: updateController.checkForUpdates)
                    .disabled(!updateController.isConfigured || !updateController.canCheckForUpdates)

                if !updateController.isConfigured {
                    Label("当前安装包尚未配置在线更新源", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("反馈与建议") {
                if OnlineServiceConfiguration.feedbackEndpoint == nil {
                    Label("当前安装包尚未配置反馈服务器；建议仍会保存在本机", systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                } else {
                    Label("在线反馈已连接", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 520)
    }
}
