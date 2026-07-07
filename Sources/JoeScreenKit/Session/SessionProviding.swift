import Foundation

/// Lifecycle of the SharePlay control-plane session as app code observes it. Mirrors the
/// GroupSession state machine without importing it, so the whole app model is testable with a
/// scripted fake provider.
public enum SessionLifecycleState: String, Codable, Sendable, Equatable {
    /// No session; the user hasn't started or joined anything.
    case idle
    /// `prepareForActivation()`/join is in flight (system sheet may be up).
    case activating
    /// `GroupSession.join()` succeeded; messenger + journal are usable.
    case joined
    /// The session ended or errored; all messengers derived from it are dead.
    case invalidated
}

/// The ONE seam through which JoeScreen touches GroupActivities (spec R12: SharePlay API drift /
/// entitlement flakiness is quarantined behind a protocol so the rest of the app never imports
/// the framework). Everything above this protocol — RoomModel sync, signaling, admission,
/// authorization — is pure Swift and unit-tested against a fake `SessionProviding`.
///
/// Contract notes for implementers:
///  - `ParticipantID` mirrors `Participant.id` (an opaque UUID — the only identity SharePlay
///    exposes); the implementation must surface exactly that UUID so capability grants and
///    media-plane identity binding (`MediaTransport.bindIdentity`) agree across peers.
///  - Control-plane messaging (GroupSessionMessenger) is NOT exposed here raw: sends must go
///    through `SignalingSendQueue` (D9) so the messenger's burst throttle (R10) is respected.
///  - Implementations are reference types living in the app layer; they must be Sendable
///    (actor-isolated) because callers hop isolation domains.
///
/// // TODO(Phase1): implement `GroupSessionCoordinator` (app layer) — observes
/// // `JoeScreenActivity.sessions()`, joins, republishes participant sets and state through
/// // these streams, and hands `GroupSessionMessenger` sends to `SignalingSendQueue`.
/// // TODO(Phase1): ship a `FakeSessionProvider` in the test support target for model tests.
public protocol SessionProviding: Sendable {

    /// Start (host) a new session for `activity`. Implementations call
    /// `prepareForActivation()`/`activate()`; throwing means the user declined or the
    /// entitlement/system flow failed.
    func start(_ activity: JoeScreenActivity) async throws

    /// Join the already-incoming session for our activity (the system delivered one via
    /// `sessions()`). No-op when already `.joined`.
    func join() async

    /// Leave the current session locally (others continue). Transitions to `.invalidated`.
    func leave() async

    /// The local participant's SharePlay identity, once `.joined`; `nil` before.
    var localParticipantID: ParticipantID? { get async }

    /// Current lifecycle snapshot followed by every subsequent transition.
    func stateUpdates() -> AsyncStream<SessionLifecycleState>

    /// Current active-participant set followed by every membership change. The set INCLUDES the
    /// local participant (matches `GroupSession.activeParticipants` semantics).
    func participantUpdates() -> AsyncStream<Set<ParticipantID>>
}
