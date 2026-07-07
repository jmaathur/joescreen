import SwiftUI
import Observation
import JoeScreenKit

/// The central @MainActor observable app state and orchestrator for the macOS client.
///
/// It owns the connection lifecycle (Direct Session Mode → LiveKit media plane), the roster, the
/// mirrored `RoomModel`, and the set of remote shared windows currently rendered as native NSWindows.
/// The heavy transport wiring lands in M2 (`LiveKitTransport`), capture in M3, the call UI in M4,
/// voice in M5, cursors in M6; M1 establishes the shape and a launchable app.
@MainActor
@Observable
public final class AppModel {

    /// High-level UI phase, distinct from the media `MediaConnectionState` (which the connection
    /// banner surfaces separately once M2 lands).
    public enum Phase: Equatable {
        case idle              // no session; join sheet is the primary affordance
        case connecting        // dialing the SFU
        case inCall            // connected; roster + shares live
        case failed(String)    // terminal error; message shown, retry offered
    }

    // MARK: - Observable state

    public private(set) var phase: Phase = .idle
    /// The parameters of the current/last join attempt (server/room/identity).
    public private(set) var joinParameters: DirectJoinParameters?
    /// Local participant identity (the UUID parsed from the join identity). Set on successful join.
    public private(set) var localParticipantID: ParticipantID?
    /// The mirrored room state (who shares which windows, modes, pause). Sharer broadcasts; joiners
    /// apply (M4). Starts empty.
    public private(set) var room = RoomModel()
    /// Active participant set (includes local), driven by the transport/session (M2/M7).
    public private(set) var participants: Set<ParticipantID> = []
    /// Media-plane connection state banner (M2).
    public private(set) var mediaState: MediaConnectionState = .disconnected
    /// Whether the join sheet should be shown (no direct-join pending, not in a call).
    public var showJoinSheet: Bool = true

    /// A pending launch-arg join to fire on first scene appearance (§1 zero-click demo path).
    private var launchJoin: DirectJoinParameters?
    private var launchJoinFired = false

    public init(launchJoin: DirectJoinParameters? = nil) {
        self.launchJoin = launchJoin
        // If we were launched to auto-join, don't pop the sheet — go straight to connecting.
        if launchJoin != nil { self.showJoinSheet = false }
    }

    // MARK: - Join entry points

    /// Fire the launch-argument join exactly once, when the first scene appears.
    public func startLaunchJoinIfNeeded() {
        guard !launchJoinFired, let params = launchJoin else { return }
        launchJoinFired = true
        requestJoin(params)
    }

    /// Begin joining a Direct Session Mode call. Idempotent-ish: a new request supersedes the sheet.
    public func requestJoin(_ params: DirectJoinParameters) {
        joinParameters = params
        localParticipantID = params.participantID
        showJoinSheet = false
        phase = .connecting
        // M2 wires the real LiveKitTransport connect here. For M1 the app is launchable and the
        // connecting state is shown; the transport call is added when the adapter lands.
        connect(params)
    }

    /// Leave the current call and return to idle.
    public func leave() {
        phase = .idle
        participants = []
        room = RoomModel()
        localParticipantID = nil
        mediaState = .disconnected
        showJoinSheet = true
        // M2: disconnect the transport; M4: close remote windows.
        teardown()
    }

    // MARK: - Transport seam (filled in M2)

    private func connect(_ params: DirectJoinParameters) {
        // TODO(M2): mint a dev JWT (DevTokenMinter), build MediaTransportConfiguration, connect the
        // LiveKitTransport actor, bridge connectionStates()/participantUpdates() into `phase`,
        // `mediaState`, `participants`. For M1 we mark the intent and stay in `.connecting` so the
        // app launches and the UI renders truthfully.
        _ = params
    }

    private func teardown() {
        // TODO(M2): await transport.disconnect(); unpublish tracks; close remote NSWindows.
    }

    // MARK: - Sharing (wired to the picker in M3/M4)

    /// One shared-window entry for the UI grid.
    public struct SharedWindowEntry: Equatable {
        public let window: WindowID
        public let owner: ParticipantID
    }

    /// Windows currently shared in the room, in stable UUID order.
    public var sharedWindowsSorted: [SharedWindowEntry] {
        room.shares
            .map { SharedWindowEntry(window: $0.key, owner: $0.value) }
            .sorted { $0.window.uuidString < $1.window.uuidString }
    }

    /// Begin sharing one of the local user's windows. M3 brings up `SCContentSharingPicker`; M4
    /// wires the resulting capture into a published track and broadcasts a share event.
    public func beginShare() {
        // TODO(M3/M4): present the picker, start WindowCaptureService, publishVideoTrack, and
        // broadcast a RoomSnapshot + ShareEvent on the `state` channel.
    }

    // MARK: - Roster helpers

    /// Deterministic display color for a participant (shared across roster, window chrome, cursors).
    public func color(for id: ParticipantID) -> Color {
        let c = ParticipantColor.components(for: id)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// A short, stable label for a participant when no display name is known (first 4 hex of UUID).
    public func shortLabel(for id: ParticipantID) -> String {
        String(id.uuidString.prefix(4))
    }
}
