import Foundation
import JoeScreenKit

/// Thread-safe fan-out of `MediaConnectionState` transitions, so `MediaTransport.connectionStates()`
/// — a SYNCHRONOUS protocol requirement — can be satisfied by a `nonisolated` method on the actor
/// without crossing actor isolation (which the Swift 6 concurrency checker rejects). The actor pushes
/// state via `emit`; subscribers get the current state first, then every transition.
final class ConnectionStateBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var current: MediaConnectionState = .disconnected
    private var continuations: [UUID: AsyncStream<MediaConnectionState>.Continuation] = [:]

    /// Subscribe: yields the current state immediately, then every subsequent transition.
    func stream() -> AsyncStream<MediaConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            let now = current
            continuations[id] = continuation
            lock.unlock()
            continuation.yield(now)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Publish a state transition to all current subscribers.
    func emit(_ state: MediaConnectionState) {
        lock.lock()
        current = state
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(state) }
    }

    var value: MediaConnectionState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func finishAll() {
        lock.lock()
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }
}
