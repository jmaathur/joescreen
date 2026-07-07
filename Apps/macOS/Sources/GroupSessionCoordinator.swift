import Foundation
import JoeScreenKit

#if canImport(GroupActivities)
import GroupActivities
import Combine

/// The ONE seam through which JoeScreen touches SharePlay (spec D9 / R12 / M7). Conforms to
/// `SessionProviding` so everything above it (roster, RoomModel sync, admission, authorization) stays
/// pure and testable against `FakeSessionProvider`.
///
/// SharePlay is COORDINATION ONLY (D9): it carries session membership, presence, and the small
/// `TransportBootstrap {serverURL, roomName, jwt}` + room-state snapshots over `GroupSessionMessenger`
/// (≤200 KB, via `SignalingSendQueue` with retry/backoff — landmine #1 / R10). Media NEVER touches
/// the messenger; the LiveKit `MediaTransport` connects independently using the bootstrap, and media
/// survives `GroupSession` invalidation (R28).
///
/// Reuses `JoeScreenActivity`'s existing `GroupActivity` conformance (JoeScreenKit already conforms it
/// behind `#if canImport(GroupActivities)`) — it does NOT re-declare it (that would be a duplicate
/// conformance). Requires the `com.apple.developer.group-session` entitlement (TEAM_ID-gated in M1),
/// so its RUNTIME is a hardware step (2 devices, different iCloud accounts) — PENDING in TESTING.md.
@available(macOS 14.0, *)
public final class GroupSessionCoordinator: SessionProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var groupSession: GroupSession<JoeScreenActivity>?
    private var messenger: GroupSessionMessenger?
    private var sendQueue = SignalingSendQueue()
    private var subscriptions = Set<AnyCancellable>()
    private var sessionTask: Task<Void, Never>?
    private var localID: ParticipantID?

    private var stateContinuations: [UUID: AsyncStream<SessionLifecycleState>.Continuation] = [:]
    private var participantContinuations: [UUID: AsyncStream<Set<ParticipantID>>.Continuation] = [:]

    /// Latest bootstrap the host published, re-sent to late joiners (R28).
    private var lastBootstrap: TransportBootstrap?
    /// Latest room snapshot, re-broadcast to late joiners.
    private var lastRoomSnapshot: RoomModel?

    /// Callback: a joiner received the host's transport bootstrap → connect the media plane.
    public var onBootstrap: (@Sendable (TransportBootstrap) -> Void)?
    /// Callback: a room-state snapshot arrived over the coordination plane.
    public var onRoomSnapshot: (@Sendable (RoomModel) -> Void)?

    public init() {
        // Begin observing incoming sessions for our activity immediately (the system delivers one
        // when a peer starts the activity or the local user activates it).
        sessionTask = Task { [weak self] in
            for await session in JoeScreenActivity.sessions() {
                await self?.configure(session: session)
            }
        }
    }

    // MARK: - SessionProviding

    /// Start (host) a session. Activation: prepareForActivation() → GroupActivityActivationResult
    /// (NOT Bool) → activate(). Throws if the user declines or the entitlement/system flow fails.
    public func start(_ activity: JoeScreenActivity) async throws {
        emitState(.activating)
        let result = await activity.prepareForActivation()
        switch result {
        case .activationPreferred:
            _ = try await activity.activate()
            // The active session arrives via `sessions()`; `configure` joins + wires it.
        case .activationDisabled:
            // Not eligible (e.g. no FaceTime call). The caller's fallback presents
            // GroupActivitySharingController (see GroupActivityPresenter) or ShareLink.
            emitState(.idle)
            throw CoordinatorError.activationDisabled
        case .cancelled:
            emitState(.idle)
            throw CoordinatorError.cancelled
        @unknown default:
            emitState(.idle)
            throw CoordinatorError.cancelled
        }
    }

    public func join() async {
        let session = lock.withLock { groupSession }
        session?.join()
    }

    public func leave() async {
        let session = lock.withLock { () -> GroupSession<JoeScreenActivity>? in
            let s = groupSession
            groupSession = nil
            messenger = nil
            subscriptions.removeAll()
            return s
        }
        session?.leave()
        emitState(.invalidated)
    }

    public var localParticipantID: ParticipantID? {
        get async { lock.withLock { localID } }
    }

    public func stateUpdates() -> AsyncStream<SessionLifecycleState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); stateContinuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.stateContinuations.removeValue(forKey: id) }
            }
        }
    }

    public func participantUpdates() -> AsyncStream<Set<ParticipantID>> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); participantContinuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.participantContinuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - Host publish (coordination plane)

    /// Host: publish the media-plane bootstrap to all participants (and remember it for late joiners).
    public func publishBootstrap(_ bootstrap: TransportBootstrap) {
        lock.withLock { lastBootstrap = bootstrap }
        enqueueCoordination(.bootstrap(bootstrap))
    }

    /// Host: broadcast a room-state snapshot (revision-gated LWW on the receiver), remembered for
    /// late joiners (R28).
    public func broadcastRoomSnapshot(_ model: RoomModel) {
        lock.withLock { lastRoomSnapshot = model }
        enqueueCoordination(.roomSnapshot(model))
    }

    // MARK: - Session wiring

    private func configure(session: GroupSession<JoeScreenActivity>) async {
        let messenger = lock.withLock { () -> GroupSessionMessenger in
            groupSession = session
            let m = GroupSessionMessenger(session: session)
            self.messenger = m
            return m
        }

        // Observe active participants → republish the roster.
        session.$activeParticipants
            .sink { [weak self] participants in
                let ids = Set(participants.map { $0.id })
                self?.emitParticipants(ids)
            }
            .store(in: &subscriptions)

        // Observe session state → mirror lifecycle.
        session.$state
            .sink { [weak self] state in
                switch state {
                case .waiting:   self?.emitState(.activating)
                case .joined:    self?.emitState(.joined)
                case .invalidated: self?.emitState(.invalidated) // media survives (R28)
                @unknown default: break
                }
            }
            .store(in: &subscriptions)

        // Receive coordination messages (bootstrap + snapshots).
        Task { [weak self] in
            for await (data, _) in messenger.messages(of: Data.self) {
                self?.handleIncoming(data)
            }
        }

        // Drive the send queue on a timer (retry/backoff/stagger honored by SignalingSendQueue).
        startSendPump(messenger: messenger)

        session.join()
        lock.withLock { localID = session.localParticipant.id }
        emitState(.joined)

        // Late-joiner catch-up: re-send whatever we last published (R28).
        if let boot = lock.withLock({ lastBootstrap }) { enqueueCoordination(.bootstrap(boot)) }
        if let snap = lock.withLock({ lastRoomSnapshot }) { enqueueCoordination(.roomSnapshot(snap)) }
    }

    private func handleIncoming(_ data: Data) {
        guard let message = try? CoordinationMessage.decode(data) else { return }
        switch message {
        case .bootstrap(let boot): onBootstrap?(boot)
        case .roomSnapshot(let model): onRoomSnapshot?(model)
        }
    }

    private func enqueueCoordination(_ message: CoordinationMessage) {
        guard let bytes = try? message.encoded() else { return }
        // SignalingSendQueue enforces the ≤200 KB cap + backpressure before the messenger (R10).
        lock.withLock {
            _ = try? sendQueue.enqueue(bytes, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func startSendPump(messenger: GroupSessionMessenger) {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let item: SignalingSendQueue.Item? = self.lock.withLock { self.sendQueue.nextReady(now: now) }
                if let item {
                    do {
                        try await messenger.send(item.payload)
                        self.lock.withLock { self.sendQueue.reportSuccess(item.id) }
                    } catch {
                        // A messenger throw is the authoritative throttle/oversize signal (R10):
                        // retry with backoff.
                        self.lock.withLock { _ = self.sendQueue.reportFailure(item.id, now: now) }
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }

    // MARK: - Emit helpers

    private func emitState(_ state: SessionLifecycleState) {
        let conts = lock.withLock { Array(stateContinuations.values) }
        for c in conts { c.yield(state) }
    }

    private func emitParticipants(_ ids: Set<ParticipantID>) {
        let conts = lock.withLock { Array(participantContinuations.values) }
        for c in conts { c.yield(ids) }
    }

    public enum CoordinatorError: Error, Equatable {
        case activationDisabled
        case cancelled
    }
}

#endif
