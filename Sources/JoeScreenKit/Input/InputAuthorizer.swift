import Foundation

/// Owner-side authorization decision made AT INJECTION TIME (spec §3.5 / D12). This is the
/// highest-consequence seam in the app: a non-sandboxed, Accessibility-privileged process is about
/// to synthesize input on behalf of a remote peer. Every check here runs against TRUSTED LOCAL
/// STATE on the owner, never against in-band flags carried on the coordination plane (which are
/// forgeable relative to the data plane).
public struct InputAuthorizer: Sendable {

    /// The trusted local state the owner evaluates against. All of this is owner-owned; none of it
    /// is taken from the incoming message.
    public struct OwnerState: Sendable {
        /// Whether the owner has globally enabled remote control at all (sharer master switch).
        public var remoteControlEnabled: Bool
        /// Per-window interaction mode as the OWNER sees it (default `.watch`).
        public var modeByWindow: [WindowID: InteractionMode]
        /// Owner's capability store (grants/expiry).
        public var capabilities: CapabilityStore
        /// Per-window soft single-active-controller lock.
        public var locksByWindow: [WindowID: ActiveControllerLock]
        /// The set of window IDs this owner actually owns/shares (a peer may not address others).
        public var ownedWindows: Set<WindowID>

        public init(
            remoteControlEnabled: Bool = false,
            modeByWindow: [WindowID: InteractionMode] = [:],
            capabilities: CapabilityStore = CapabilityStore(),
            locksByWindow: [WindowID: ActiveControllerLock] = [:],
            ownedWindows: Set<WindowID> = []
        ) {
            self.remoteControlEnabled = remoteControlEnabled
            self.modeByWindow = modeByWindow
            self.capabilities = capabilities
            self.locksByWindow = locksByWindow
            self.ownedWindows = ownedWindows
        }
    }

    public enum Decision: Equatable, Sendable {
        case inject                       // authorized; clamp coords and post the CGEvent
        case denyGlobalDisabled           // owner has remote control off entirely
        case denyUnknownWindow            // window not owned by this owner
        case denyWatchMode                // window is in Watch mode; no injection
        case denyNoWriteAccess            // no valid capability with .write
        case denyPeerIdentityMismatch     // message sender ≠ transport-authenticated peer
        case denyNotActiveController      // another participant holds the single-active lock
    }

    public init() {}

    /// Authorize one discrete input event.
    /// - Parameters:
    ///   - event: the received input payload.
    ///   - messageSender: the `senderID` inside the envelope (claimed identity).
    ///   - transportPeer: the DTLS/SFU-authenticated peer identity that actually delivered it.
    ///     If these disagree, the message is spoofed → reject. This binds data-channel input to
    ///     the authenticated peer (spec §3.5 point 1).
    ///   - state: the owner's trusted local state.
    ///   - now: owner clock for capability expiry.
    public func authorize(
        event: InputEvent,
        messageSender: ParticipantID,
        transportPeer: ParticipantID,
        state: OwnerState,
        now: Double
    ) -> Decision {
        // 1. Bind claimed identity to the authenticated transport peer.
        guard messageSender == transportPeer else { return .denyPeerIdentityMismatch }

        // 2. Master switch.
        guard state.remoteControlEnabled else { return .denyGlobalDisabled }

        // 3. The peer may only address windows this owner actually owns.
        guard state.ownedWindows.contains(event.windowID) else { return .denyUnknownWindow }

        // 4. Window must be in Control mode (Watch is the default and drops injection).
        let mode = state.modeByWindow[event.windowID] ?? .watch
        guard mode == .control else { return .denyWatchMode }

        // 5. A valid, unexpired capability with .write must exist for THIS participant+window.
        guard let cap = state.capabilities.capability(participant: messageSender, window: event.windowID, now: now),
              cap.rights.contains(.write) else {
            return .denyNoWriteAccess
        }

        // 6. Soft single-active-controller lock: if someone else is driving, this peer waits.
        if let lock = state.locksByWindow[event.windowID], let holder = lock.holder, holder != messageSender {
            return .denyNotActiveController
        }

        return .inject
    }
}
