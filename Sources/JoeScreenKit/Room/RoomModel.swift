import Foundation

/// The mirrored control-plane snapshot of one session's shared-desktop state: who is sharing
/// which windows, each participant's per-window interaction mode, advisory write-access flags,
/// and per-share pause state (spec §3.1/§3.3).
///
/// Trust model (spec §3.5): this model is ADVISORY — it drives UI (roster, window chrome, mode
/// tabs) on every peer. It never authorizes anything by itself: the owner's `CapabilityStore` +
/// `InputAuthorizer` remain the injection-time source of truth. A peer lying in its mirrored
/// RoomModel gains nothing.
///
/// Sync model: each participant mutates its copy and broadcasts snapshots over the control plane
/// (D9); discrete share/unshare changes also go out as ordered ShareEvents on the same channel.
/// Receivers UNION-MERGE snapshot shares per windowID (see `merge(snapshot:excludingOwner:)`) —
/// per-process revision counters start at 0 on every peer, so a last-writer-wins revision gate
/// collides across concurrent sharers and silently drops foreign shares. `revision` still stamps
/// outgoing snapshots/ShareEvents for ordering diagnostics; every state-changing mutation below
/// bumps it exactly once, so revision changes always mean visible state changes.
public struct RoomModel: Codable, Sendable, Equatable {

    /// Whether a share's video is flowing or intentionally frozen (owner minimized/occluded the
    /// window, or paused explicitly — see `PauseDetector` on the capture side).
    public enum PauseState: String, Codable, Sendable, Equatable {
        case live
        case paused
    }

    /// Shared windows: windowID → owning participant. A window has exactly one owner; an owner
    /// may share several windows (subject to `AdmissionController`).
    public private(set) var shares: [WindowID: ParticipantID]

    /// Per-window, per-participant interaction mode (F10). Stored SPARSELY: absence means the
    /// default `.watch` — a participant never injects until they explicitly switch modes.
    public private(set) var controlModes: [WindowID: [ParticipantID: InteractionMode]]

    /// Advisory write-access flags per window (who the owner has granted `.write` to), mirrored
    /// for UI badges. The authoritative grant lives in the owner's `CapabilityStore`.
    public private(set) var writeAccess: [WindowID: Set<ParticipantID>]

    /// Pause state per shared window. Defaults to `.live` when a share is added.
    public private(set) var pauseStates: [WindowID: PauseState]

    /// Monotonic snapshot revision. Starts at 0 for an empty room; strictly increases with every
    /// effective mutation. Wrapping addition is used defensively but a UInt64 never wraps in
    /// practice.
    public private(set) var revision: UInt64

    public init() {
        self.shares = [:]
        self.controlModes = [:]
        self.writeAccess = [:]
        self.pauseStates = [:]
        self.revision = 0
    }

    // MARK: - Mutations (each bumps `revision` iff state actually changed)

    /// Add a share for `windowID` owned by `owner`. Fails (returns false, no bump) if the window
    /// is already shared — window IDs are owner-assigned and unique within a session.
    @discardableResult
    public mutating func addShare(_ windowID: WindowID, owner: ParticipantID) -> Bool {
        guard shares[windowID] == nil else { return false }
        shares[windowID] = owner
        pauseStates[windowID] = .live
        bump()
        return true
    }

    /// Remove a share and all state hanging off it (modes, write access, pause state).
    @discardableResult
    public mutating func removeShare(_ windowID: WindowID) -> Bool {
        guard shares.removeValue(forKey: windowID) != nil else { return false }
        controlModes[windowID] = nil
        writeAccess[windowID] = nil
        pauseStates[windowID] = nil
        bump()
        return true
    }

    /// Set `participant`'s interaction mode on a shared window. `.watch` (the default) is stored
    /// sparsely by clearing the entry. Fails for unknown windows.
    @discardableResult
    public mutating func setControlMode(
        _ mode: InteractionMode, participant: ParticipantID, window: WindowID
    ) -> Bool {
        guard shares[window] != nil else { return false }
        let current = controlModes[window]?[participant] ?? .watch
        guard current != mode else { return false }
        if mode == .watch {
            controlModes[window]?[participant] = nil
            if controlModes[window]?.isEmpty == true { controlModes[window] = nil }
        } else {
            controlModes[window, default: [:]][participant] = mode
        }
        bump()
        return true
    }

    /// Mirror an owner grant/revoke of write access for UI. Fails for unknown windows; no bump
    /// when the flag is already in the requested state.
    @discardableResult
    public mutating func setWriteAccess(
        _ granted: Bool, participant: ParticipantID, window: WindowID
    ) -> Bool {
        guard shares[window] != nil else { return false }
        if granted {
            guard writeAccess[window, default: []].insert(participant).inserted else { return false }
        } else {
            guard writeAccess[window]?.remove(participant) != nil else { return false }
            if writeAccess[window]?.isEmpty == true { writeAccess[window] = nil }
        }
        bump()
        return true
    }

    /// Set a share's pause state. Fails for unknown windows; no bump when unchanged.
    @discardableResult
    public mutating func setPauseState(_ state: PauseState, window: WindowID) -> Bool {
        guard shares[window] != nil, pauseStates[window] != state else { return false }
        pauseStates[window] = state
        bump()
        return true
    }

    /// A participant left the session: their shares end, and every mode/write-access entry they
    /// held on other windows is cleared. Single revision bump for the whole cascade.
    @discardableResult
    public mutating func removeParticipant(_ participant: ParticipantID) -> Bool {
        var changed = false

        // Their own shares disappear with them (cascade like removeShare, without per-step bumps).
        for (window, owner) in shares where owner == participant {
            shares[window] = nil
            controlModes[window] = nil
            writeAccess[window] = nil
            pauseStates[window] = nil
            changed = true
        }

        // Their presence on everyone else's windows is cleared.
        for window in Array(controlModes.keys) {
            if controlModes[window]?.removeValue(forKey: participant) != nil {
                if controlModes[window]?.isEmpty == true { controlModes[window] = nil }
                changed = true
            }
        }
        for window in Array(writeAccess.keys) {
            if writeAccess[window]?.remove(participant) != nil {
                if writeAccess[window]?.isEmpty == true { writeAccess[window] = nil }
                changed = true
            }
        }

        if changed { bump() }
        return changed
    }

    /// Union-merge a foreign snapshot into this copy (receiver side of the D9 sync). Every share
    /// the snapshot knows that we don't is added; shares we already know are KEPT even when absent
    /// from the snapshot — unshares travel as ordered ShareEvents on the same channel, never via
    /// snapshots, so a stale/reordered snapshot can't resurrect or drop a share. Pause states for
    /// shares both sides know adopt the snapshot's value so pause updates keep flowing. Entries
    /// owned by `excludingOwner` (the local participant) are skipped entirely: that participant is
    /// the authoritative source for its own shares, so a stale foreign mirror can never resurrect
    /// a share it just ended or stomp its pause state. Replaces the old last-writer-wins
    /// whole-model replace, whose per-process revision counters collided across peers and silently
    /// dropped foreign shares. Bumps `revision` once iff anything changed.
    @discardableResult
    public mutating func merge(snapshot other: RoomModel, excludingOwner: ParticipantID? = nil) -> Bool {
        var changed = false
        for (window, owner) in other.shares where owner != excludingOwner {
            if shares[window] == nil {
                shares[window] = owner
                pauseStates[window] = other.pauseStates[window] ?? .live
                changed = true
            } else if let state = other.pauseStates[window], pauseStates[window] != state {
                pauseStates[window] = state
                changed = true
            }
        }
        if changed { bump() }
        return changed
    }

    // MARK: - Queries

    public func owner(of window: WindowID) -> ParticipantID? {
        shares[window]
    }

    /// Interaction mode for a participant on a window; `.watch` unless explicitly changed (F10).
    public func controlMode(of participant: ParticipantID, in window: WindowID) -> InteractionMode {
        controlModes[window]?[participant] ?? .watch
    }

    /// Advisory write-access flag (UI badge); NOT an authorization check.
    public func hasWriteAccess(_ participant: ParticipantID, in window: WindowID) -> Bool {
        writeAccess[window]?.contains(participant) ?? false
    }

    /// Pause state of a shared window; `nil` if the window isn't shared.
    public func pauseState(of window: WindowID) -> PauseState? {
        pauseStates[window]
    }

    /// All windows currently shared by `participant`, in stable (UUID-sorted) order.
    public func windows(ownedBy participant: ParticipantID) -> [WindowID] {
        shares.filter { $0.value == participant }
            .keys
            .sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: -

    private mutating func bump() {
        revision &+= 1
    }
}
