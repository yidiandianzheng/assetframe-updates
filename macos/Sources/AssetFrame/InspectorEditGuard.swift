import SwiftUI

/// Keeps navigation pending until the inspector draft is explicitly resolved.
@MainActor
final class InspectorEditGuard: ObservableObject {
    private final class WeakGuard {
        weak var value: InspectorEditGuard?
        init(_ value: InspectorEditGuard) { self.value = value }
    }
    private static var guards: [WeakGuard] = []
    private var exitDecision: CheckedContinuation<Bool, Never>?

    init() {
        Self.guards.removeAll { $0.value == nil }
        Self.guards.append(WeakGuard(self))
    }

    static func prepareToTerminate() async -> Bool {
        for guardrail in guards.compactMap(\.value) {
            guard await guardrail.resolveBeforeTermination() else { return false }
        }
        return true
    }

    func resolveBeforeTermination() async -> Bool {
        guard !isSaving, navigation == nil, exitDecision == nil else { return false }
        guard dirty else { return true }
        return await withCheckedContinuation { continuation in
            exitDecision = continuation
            request { [weak self] in self?.finishExit(true) }
        }
    }

    private func finishExit(_ allowed: Bool) {
        let pending = exitDecision
        exitDecision = nil
        pending?.resume(returning: allowed)
    }
    @Published var needsDecision = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    var dirty = false
    var save: (() async -> Bool)?
    var discard: (() -> Void)?
    private var navigation: (() -> Void)?

    func request(_ action: @escaping () -> Void) {
        guard !isSaving else { return }
        guard dirty else { action(); return }
        guard navigation == nil else { return }
        navigation = action
        error = nil
        needsDecision = true
    }

    func cancel() {
        navigation = nil
        needsDecision = false
        error = nil
        finishExit(false)
    }

    func discardAndContinue() {
        discard?()
        dirty = false
        finish()
    }

    func saveAndContinue() async {
        guard !isSaving, let save else { return }
        isSaving = true
        let success = await save()
        isSaving = false
        if success {
            dirty = false
            finish()
        } else {
            error = "保存未成功，草稿仍保留。请检查素材库写入状态后重试。"
            needsDecision = true
        }
    }

    private func finish() {
        let action = navigation
        navigation = nil
        needsDecision = false
        error = nil
        action?()
    }
}
