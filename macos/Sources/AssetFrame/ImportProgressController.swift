import Combine
import Foundation

/// Publishes high-frequency import progress independently from `AssetStore`.
/// This keeps gallery and folder views from recomputing for every progress tick.
@MainActor
final class ImportProgressController: ObservableObject {
    private(set) var job: ImportJobProgress?
    @Published private(set) var state: ImportProgressState?

    func replace(with state: ImportProgressState?) {
        if let current = self.state, let state, current.id == state.id,
           current.phase == .completed, state.phase != .completed { return }
        if let state {
            if job?.id != state.id { job = ImportJobProgress(id: state.id, stage: "正在发现素材") }
            job?.advance(stage: state.phase == .scanning ? "正在发现素材" : "正在登记素材",
                discovered: state.total, registered: state.imported, skipped: state.skipped, failed: 0,
                scanCompleted: state.phase != .scanning, finished: state.phase == .completed)
        } else { job = nil }
        self.state = state
    }
}
