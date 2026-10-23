import Combine
import Foundation

@main
enum ImportProgressIsolationSelfTest {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetFrame-ImportProgressIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AssetStore(rootURL: root)
        while store.isLoadingProject {
            try? await Task.sleep(for: .milliseconds(20))
        }

        var storeChanges = 0
        var progressChanges = 0
        let storeObservation = store.objectWillChange.sink { storeChanges += 1 }
        let progressObservation = store.importProgressController.objectWillChange.sink { progressChanges += 1 }
        _ = (storeObservation, progressObservation)

        let jobID = UUID()
        for index in 0..<1_000 {
            store.importProgress = ImportProgressState(
                id: jobID,
                phase: .importing,
                total: 1_000,
                processed: index + 1,
                imported: 0,
                skipped: index + 1,
                currentFilename: "duplicate-\(index).png",
                kind: .pendingStage
            )
        }

        precondition(progressChanges == 1_000, "进度控制器必须发布每次状态变化")
        precondition(storeChanges == 0, "导入进度不得触发 AssetStore 全局刷新")
        precondition(store.importProgress?.processed == 1_000)
        print("ImportProgressIsolationSelfTest passed")
    }
}
