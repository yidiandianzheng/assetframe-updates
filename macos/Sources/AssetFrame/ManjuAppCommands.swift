import SwiftUI

struct ManjuAppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建漫剧项目…") {
                NotificationCenter.default.post(name: .manageStoryProjects, object: nil, userInfo: ["action": "create"])
            }.keyboardShortcut("n", modifiers: [.command])
            Button("项目管理…") { NotificationCenter.default.post(name: .manageStoryProjects, object: nil) }
                .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(replacing: .help) {
            Button("更新日志…") {
                NotificationCenter.default.post(name: .showUpdateLog, object: nil)
            }
        }
    }
}
