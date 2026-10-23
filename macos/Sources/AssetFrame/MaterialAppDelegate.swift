import AppKit

@MainActor
final class MaterialAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateCancel }
        terminationPending = true
        Task {
            guard await InspectorEditGuard.prepareToTerminate() else {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await GlobalMaterialStore.finishBeforeTermination()
            let saved = await LibrarySession.finishBeforeTermination()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
