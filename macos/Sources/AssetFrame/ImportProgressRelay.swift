import Foundation

/// A single pending sample and a single delivery task. Producers never wait
/// for the UI; newer samples replace older undelivered samples.
final class ImportProgressRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var delivering = false
    private let deliver: @Sendable (Value) async -> Void
    init(deliver: @escaping @Sendable (Value) async -> Void) { self.deliver = deliver }
    func submit(_ value: Value) {
        lock.lock()
        pending = value
        let shouldStart = !delivering
        delivering = true
        lock.unlock()
        if shouldStart {
            Task {
                while let next = take() { await deliver(next) }
            }
        }
    }
    private func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let value = pending
        pending = nil
        if value == nil { delivering = false }
        return value
    }
}
