import Foundation

/// The interaction mode of a shared window from a given participant's perspective (spec F10).
/// Default is `.watch` — no injection happens until a user EXPLICITLY takes control.
public enum InteractionMode: String, Codable, Sendable {
    case watch    // view only; injection dropped
    case control  // may inject input (gated by capability + write access)
    case draw     // may ink annotations (gated by capability .draw)
}

/// An owner-issued capability binding data-plane input rights to a specific participant+window.
/// The owner is the source of truth: a peer's in-band control flags are ADVISORY and never
/// authorize on their own (spec §3.5). A capability is only valid if it was issued by the owner
/// for THIS participant and window and has not expired/been revoked.
public struct Capability: Sendable, Equatable {
    public var participantID: ParticipantID
    public var windowID: WindowID
    public var rights: ControlRights
    /// Owner-clock expiry (seconds since reference). `nil` = no expiry.
    public var expiry: Double?

    public init(participantID: ParticipantID, windowID: WindowID, rights: ControlRights, expiry: Double? = nil) {
        self.participantID = participantID; self.windowID = windowID
        self.rights = rights; self.expiry = expiry
    }

    public func isValid(now: Double) -> Bool {
        guard let expiry else { return true }
        return now < expiry
    }
}

/// The owner's trusted local store of capabilities. Lives ONLY on the owner Mac; grants/revokes
/// are mirrored to peers for UI, but authorization reads this store, not the wire.
public struct CapabilityStore: Sendable {
    private var byKey: [Key: Capability] = [:]

    private struct Key: Hashable { let p: ParticipantID; let w: WindowID }

    public init() {}

    public mutating func grant(_ cap: Capability) {
        byKey[Key(p: cap.participantID, w: cap.windowID)] = cap
    }

    public mutating func revoke(participant: ParticipantID, window: WindowID) {
        byKey[Key(p: participant, w: window)] = nil
    }

    public func capability(participant: ParticipantID, window: WindowID, now: Double) -> Capability? {
        guard let cap = byKey[Key(p: participant, w: window)], cap.isValid(now: now) else { return nil }
        return cap
    }
}

/// The soft single-active-controller lock for one window (F5): at most one participant may be the
/// active driver at a time; others must wait their turn. This is NOT simultaneous injection into
/// one field (which interleaves into gibberish — an explicit non-goal, no CRDT).
public struct ActiveControllerLock: Sendable, Equatable {
    /// Current holder, or `nil` if the window is free to take.
    public private(set) var holder: ParticipantID?

    public init(holder: ParticipantID? = nil) { self.holder = holder }

    /// Try to take the lock. Succeeds if free; a no-op success if already held by `p`.
    public mutating func take(_ p: ParticipantID) -> Bool {
        if holder == nil || holder == p { holder = p; return true }
        return false
    }

    /// Release the lock iff `p` holds it. Atomic hand-off is take-after-release by the next driver.
    public mutating func release(_ p: ParticipantID) {
        if holder == p { holder = nil }
    }

    public func isHeld(by p: ParticipantID) -> Bool { holder == p }
}
