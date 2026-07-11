import Foundation

/// The pure state machine for ONE remote-share viewer window (spec §3 / M9). Every dead-window and
/// desync bug class the mapping pass found — a frozen ghost after the sharer crashes, a duplicate
/// window on reopen, an SFU blip flapping the window closed, a soft-hidden window still eating
/// downlink — becomes an enumerable transition here. `AppModel` holds no lifecycle branching; it
/// feeds events in and EXECUTES the returned effects (open/close an NSWindow, (un)subscribe the
/// track, attach/detach the renderer, purge the entry). Because it is pure, the whole matrix is
/// unit-tested without a window server, a network, or a second Mac.
///
/// Design notes:
///  • Hard vs soft hiding (R24/R32): a user-close or a terminal-gone HARD-unsubscribes
///    (`set(subscribed:false)` = zero downlink). Miniaturize/occlusion SOFT-hides — it only detaches
///    the renderer; adaptive-stream's own timer then tells the SFU to stop forwarding. We NEVER call
///    `set(enabled:)` (throws under adaptiveStream — see constraints); the effects encode exactly
///    which lever to pull.
///  • Reconnect grace: while the media link is `.reconnecting`, a `trackGone` parks the window in
///    `.stale` (frozen frame + "Reconnecting…" badge) for a grace period instead of tearing it down,
///    so a brief SFU blip doesn't flap the window. `graceExpired` (or a real terminal signal)
///    finally purges it.
public struct RemoteWindowLifecycle: Sendable, Equatable {

    /// Why a window is soft-hidden.
    public enum HiddenReason: Sendable, Equatable {
        case miniaturized
        case occluded
    }

    /// Why a track went away (drives whether we retry or purge, and the log/telemetry reason).
    public enum GoneReason: Sendable, Equatable {
        /// The SDK reported unsubscribe/unpublish (sharer stopped, crashed, or we lost the link).
        case trackEnded
        /// The share disappeared from an authoritative RoomModel snapshot.
        case removedFromSnapshot
        /// The owning participant disconnected.
        case ownerDisconnected
    }

    public enum State: Sendable, Equatable {
        /// Subscribed, waiting for the first `RemoteVideoTrack` to arrive (no window yet).
        case subscribing
        /// Window open and rendering.
        case open
        /// The local user closed the window; entry + remembered frame kept, downlink cut. Reopenable.
        case closedByUser
        /// Renderer detached (miniaturized or fully occluded); window still exists, downlink soft-off.
        case hidden(HiddenReason)
        /// Track gone but the link is reconnecting — frozen frame held during the grace window.
        case stale
        /// Terminal: window closed, entry purged.
        case gone
    }

    /// Effects the executor (AppModel) must perform, in order, after a transition.
    public enum Effect: Sendable, Equatable {
        case openWindow
        case closeWindow
        /// Hard unsubscribe at the SFU (`set(subscribed:false)`) — zero downlink.
        case unsubscribe
        /// Hard re-subscribe (`set(subscribed:true)`) — the SDK delivers a fresh track.
        case resubscribe
        /// Soft: detach the `SwiftUIVideoView` (adaptive-stream then stops SFU forwarding).
        case pauseRendering
        /// Soft: re-attach the renderer (keyframe follows).
        case resumeRendering
        /// Drop the entry entirely.
        case purge
    }

    public private(set) var state: State

    // Context that disambiguates transitions. Tracked so overlapping visibility signals compose
    // (miniaturized AND occluded → stays hidden until BOTH clear) and reconnect-grace is honored.
    private var reconnecting: Bool
    private var miniaturized: Bool
    private var occluded: Bool

    public init(state: State = .subscribing, reconnecting: Bool = false) {
        self.state = state
        self.reconnecting = reconnecting
        self.miniaturized = false
        self.occluded = false
    }

    public enum Event: Sendable, Equatable {
        case trackSubscribed
        case trackGone(GoneReason)
        case userClosed
        case userReopened
        case miniaturized(Bool)
        case occluded(Bool)
        case shareRemovedFromSnapshot
        case ownerDisconnected
        /// The media link entered (`true`) or left (`false`) the reconnecting state.
        case transportReconnecting(Bool)
        case graceExpired
    }

    /// Apply `event`, mutating `state`/context and returning the effects to execute (possibly empty).
    @discardableResult
    public mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case .transportReconnecting(let value):
            reconnecting = value
            // Recovery does NOT itself re-open anything; a resubscribe/new track drives that. But if
            // we were parked stale and the link recovered without the track returning, we keep
            // waiting for graceExpired or a fresh trackSubscribed — no effect here.
            return []

        case .miniaturized(let value):
            miniaturized = value
            return applyVisibility()

        case .occluded(let value):
            occluded = value
            return applyVisibility()

        case .trackSubscribed:
            switch state {
            case .subscribing:
                state = .open
                return [.openWindow]
            case .stale:
                // The track came back within grace → resume the existing window.
                state = .open
                return [.resumeRendering]
            case .hidden, .open, .closedByUser, .gone:
                // Already have (or intentionally don't want) a window; a duplicate subscribe is a
                // no-op. Notably NEVER opens a second window (the duplicate-window bug).
                return []
            }

        case .trackGone(let reason):
            return handleGone(reason)

        case .userClosed:
            switch state {
            case .open, .hidden, .subscribing, .stale:
                // Remember the frame (executor's job), cut downlink, keep the entry for reopen.
                let closing: [Effect] = (state == .subscribing) ? [.unsubscribe] : [.closeWindow, .unsubscribe]
                state = .closedByUser
                miniaturized = false
                occluded = false
                return closing
            case .closedByUser, .gone:
                return []
            }

        case .userReopened:
            switch state {
            case .closedByUser:
                // Re-subscribe; the SDK delivers a NEW track that routes into THIS entry (the app's
                // openOrReplace), so no duplicate window. Window opens on the next trackSubscribed.
                state = .subscribing
                return [.resubscribe]
            default:
                return []
            }

        case .shareRemovedFromSnapshot:
            return handleGone(.removedFromSnapshot)

        case .ownerDisconnected:
            return handleGone(.ownerDisconnected)

        case .graceExpired:
            switch state {
            case .stale:
                state = .gone
                return [.closeWindow, .purge]
            default:
                return []
            }
        }
    }

    // MARK: - Helpers

    /// A terminal-ish gone signal. During reconnect it parks in `.stale`; otherwise it purges.
    private mutating func handleGone(_ reason: GoneReason) -> [Effect] {
        switch state {
        case .gone:
            // Already terminal — nothing to tear down.
            return []
        case .closedByUser:
            // The user closed the viewer (window already gone) but kept a REOPENABLE entry, which is
            // only valid while the share still exists. Any gone signal that reaches here is real (the
            // self-unsubscribe echo was suppressed in the transport), so the share is truly gone and
            // there is nothing left to reopen → purge the entry (no window to close). Prevents a stuck
            // "Reopen" tile for a share whose sharer crashed/left while its viewer was closed.
            state = .gone
            return [.purge]
        case .subscribing:
            // A bare trackEnded (crash, reconnect blip, OR a codec renegotiation republish, M11) parks
            // in .stale so a same-window resubscribe can resume the SAME window (no flicker). An
            // authoritative removal purges.
            if reason == .trackEnded {
                state = .stale
                return []
            }
            state = .gone
            return [.purge]
        case .open, .hidden, .stale:
            // A snapshot-removal or owner-disconnect is AUTHORITATIVE → purge immediately (the share
            // is really gone). A bare trackEnded — a crash, a reconnect blip, OR a codec-renegotiation
            // unpublish/republish (M11) — parks in .stale (frozen frame + grace) so the resubscribe
            // that follows a renegotiation swaps into the SAME window without a flicker; if no
            // resubscribe arrives before the grace expires the app fires graceExpired → purge.
            if reason == .trackEnded && state != .stale {
                state = .stale
                return [.pauseRendering]
            }
            state = .gone
            return [.closeWindow, .purge]
        }
    }

    /// Recompute soft-visibility from the two flags. Enters/leaves `.hidden` only from/to `.open`
    /// (a closed/gone/stale/subscribing window ignores visibility churn).
    private mutating func applyVisibility() -> [Effect] {
        let shouldHide = miniaturized || occluded
        let reason: HiddenReason = miniaturized ? .miniaturized : .occluded
        switch state {
        case .open:
            if shouldHide {
                state = .hidden(reason)
                return [.pauseRendering]
            }
            return []
        case .hidden:
            if shouldHide {
                // Still hidden but maybe the dominant reason changed — update the label, no effect.
                state = .hidden(reason)
                return []
            }
            state = .open
            return [.resumeRendering]
        default:
            return []
        }
    }
}
