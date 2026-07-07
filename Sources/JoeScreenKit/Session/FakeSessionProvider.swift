import Foundation

/// A scripted `SessionProviding` for testing the session-coordination model WITHOUT GroupActivities
/// or paired hardware (spec R12 / M7). Everything above `SessionProviding` — roster, state sync,
/// bootstrap — is pure and can be exercised by driving this fake through its lifecycle.
///
/// Implemented as an `NSLock`-guarded `final class` (not an actor) so its SYNCHRONOUS
/// `SessionProviding` requirements — `stateUpdates()`/`participantUpdates()` return `AsyncStream`
/// without `await` — can be satisfied without the actor-isolation crossing the Swift 6 checker
/// rejects. All mutable state is serialized under one lock. Shipped in JoeScreenKit (not a test-only
/// target) so unit tests and any preview/demo harness can use it.
public final class FakeSessionProvider: SessionProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var state: SessionLifecycleState = .idle
    private var participants: Set<ParticipantID> = []
    private let localID: ParticipantID
    private let startError: Error?

    private var stateContinuations: [UUID: AsyncStream<SessionLifecycleState>.Continuation] = [:]
    private var participantContinuations: [UUID: AsyncStream<Set<ParticipantID>>.Continuation] = [:]

    /// - Parameters:
    ///   - localParticipantID: the identity this fake reports as local.
    ///   - startError: if set, `start` throws it (simulate a declined/failed activation).
    public init(localParticipantID: ParticipantID = UUID(), startError: Error? = nil) {
        self.localID = localParticipantID
        self.startError = startError
    }

    // MARK: - SessionProviding

    public func start(_ activity: JoeScreenActivity) async throws {
        if let startError { throw startError }
        setState(.activating)
        setState(.joined)
        addParticipant(localID) // the local participant is always in the active set
    }

    public func join() async {
        if currentState != .joined {
            setState(.joined)
            addParticipant(localID)
        }
    }

    public func leave() async {
        setState(.invalidated)
        removeParticipant(localID)
    }

    public var localParticipantID: ParticipantID? {
        get async {
            lock.withLock { state == .joined ? localID : nil }
        }
    }

    public func stateUpdates() -> AsyncStream<SessionLifecycleState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            let now = state
            stateContinuations[id] = continuation
            lock.unlock()
            continuation.yield(now)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.stateContinuations[id] = nil; self.lock.unlock()
            }
        }
    }

    public func participantUpdates() -> AsyncStream<Set<ParticipantID>> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            let now = participants
            participantContinuations[id] = continuation
            lock.unlock()
            continuation.yield(now)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.participantContinuations[id] = nil; self.lock.unlock()
            }
        }
    }

    // MARK: - Test drivers (simulate remote peers joining/leaving)

    /// Simulate a remote participant joining the active set (a late joiner, for R28 re-broadcast tests).
    public func simulateParticipantJoined(_ id: ParticipantID) { addParticipant(id) }

    /// Simulate a participant leaving.
    public func simulateParticipantLeft(_ id: ParticipantID) { removeParticipant(id) }

    /// Simulate the session invalidating out from under us (FaceTime/GroupSession dropped — R28).
    public func simulateInvalidated() { setState(.invalidated) }

    public var currentState: SessionLifecycleState {
        lock.lock(); defer { lock.unlock() }; return state
    }

    public var currentParticipants: Set<ParticipantID> {
        lock.lock(); defer { lock.unlock() }; return participants
    }

    // MARK: - Internals

    private func setState(_ newState: SessionLifecycleState) {
        lock.lock()
        state = newState
        let conts = Array(stateContinuations.values)
        lock.unlock()
        for c in conts { c.yield(newState) }
    }

    private func addParticipant(_ id: ParticipantID) {
        lock.lock()
        let inserted = participants.insert(id).inserted
        let snapshot = participants
        let conts = Array(participantContinuations.values)
        lock.unlock()
        guard inserted else { return }
        for c in conts { c.yield(snapshot) }
    }

    private func removeParticipant(_ id: ParticipantID) {
        lock.lock()
        let removed = participants.remove(id) != nil
        let snapshot = participants
        let conts = Array(participantContinuations.values)
        lock.unlock()
        guard removed else { return }
        for c in conts { c.yield(snapshot) }
    }
}
