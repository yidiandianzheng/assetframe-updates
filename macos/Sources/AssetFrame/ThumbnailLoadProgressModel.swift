import Foundation
import Observation

@MainActor
@Observable
final class ThumbnailLoadProgressModel {
    static let shared = ThumbnailLoadProgressModel()

    private(set) var isVisible = false
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var failed = 0
    private(set) var estimatedRemainingSeconds: Double?

    private var contextID = ""
    private var pendingKeys = Set<String>()
    private var completedKeys = Set<String>()
    private var startedAt = Date.now
    private var hideTask: Task<Void, Never>?

    var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    var remainingText: String {
        guard let seconds = estimatedRemainingSeconds else { return "正在估算剩余时间…" }
        if seconds < 1 { return "预计不到 1 秒" }
        if seconds < 60 { return "预计约 \(Int(ceil(seconds))) 秒" }
        let minutes = Int(ceil(seconds / 60))
        return "预计约 \(minutes) 分钟"
    }

    func begin(contextID: String, keys: Set<String>) {
        guard !keys.isEmpty else { return }
        if self.contextID != contextID {
            reset(contextID: contextID)
        }
        let unseen = keys.subtracting(completedKeys).subtracting(pendingKeys)
        guard !unseen.isEmpty else { return }

        if pendingKeys.isEmpty {
            reset(contextID: contextID)
        }
        hideTask?.cancel()
        hideTask = nil
        pendingKeys.formUnion(unseen)
        total = completed + pendingKeys.count
        isVisible = true
        updateEstimate()
    }

    func complete(key: String, succeeded: Bool) {
        guard pendingKeys.remove(key) != nil else { return }
        completedKeys.insert(key)
        completed += 1
        if !succeeded { failed += 1 }
        total = completed + pendingKeys.count
        updateEstimate()
        guard pendingKeys.isEmpty else { return }
        estimatedRemainingSeconds = 0
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    nonisolated static func estimateSeconds(elapsed: Double, completed: Int, remaining: Int) -> Double? {
        guard elapsed >= 0.05, completed > 0, remaining > 0 else { return nil }
        return max(0, elapsed / Double(completed) * Double(remaining))
    }

    private func reset(contextID: String) {
        self.contextID = contextID
        pendingKeys.removeAll(keepingCapacity: true)
        completedKeys.removeAll(keepingCapacity: true)
        total = 0
        completed = 0
        failed = 0
        estimatedRemainingSeconds = nil
        startedAt = .now
    }

    private func updateEstimate() {
        estimatedRemainingSeconds = Self.estimateSeconds(
            elapsed: Date.now.timeIntervalSince(startedAt),
            completed: completed,
            remaining: pendingKeys.count
        )
    }
}
