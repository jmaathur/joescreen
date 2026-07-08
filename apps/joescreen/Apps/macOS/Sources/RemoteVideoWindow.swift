import SwiftUI
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// Model for one remote shared window rendered as a native NSWindow (spec §3 / M4). Holds the
/// LiveKit remote track and the owner identity that drives its color-coded chrome.
@MainActor
public final class RemoteVideoWindow: Identifiable {
    public nonisolated let windowID: WindowID
    public var ownerID: ParticipantID
    public let track: RemoteVideoTrackRef

    public init(windowID: WindowID, ownerID: ParticipantID, track: RemoteVideoTrackRef) {
        self.windowID = windowID
        self.ownerID = ownerID
        self.track = track
    }

    public nonisolated var id: WindowID { windowID }
}

/// The SwiftUI content of a remote window: the live `SwiftUIVideoView` with an owner-color border and
/// a per-participant cursor overlay (M6). Local resizing is a pure display transform — the normalized
/// coordinate mapping is unaffected (spec §3.4).
struct RemoteVideoView: View {
    let window: RemoteVideoWindow
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // The live remote video. `SwiftUIVideoView` reports adaptive-stream size/visibility
                // correctly by construction, so the SFU forwards frames (R32).
                SwiftUIVideoView(window.track, layoutMode: .fit)
                    .ignoresSafeArea()
                // Per-window cursor overlay for every remote participant (M6). Click-through:
                // CursorOverlay uses allowsHitTesting(false) so it never intercepts local input.
                CursorOverlay(windowID: window.windowID, size: geo.size)
            }
            .overlay(
                Rectangle()
                    .strokeBorder(model.color(for: window.ownerID), lineWidth: 3))
            // Outbound cursor (M6): report the LOCAL user's pointer over this remote window in
            // normalized [0,1] coords so peers see it. Local window resizing doesn't change the
            // normalized value (§3.4) — geo.size is the current view size, the pointer divides by it.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let nx = geo.size.width > 0 ? location.x / geo.size.width : 0
                    let ny = geo.size.height > 0 ? location.y / geo.size.height : 0
                    model.reportLocalCursor(
                        windowID: window.windowID,
                        point: NormalizedPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1)))
                case .ended:
                    break
                }
            }
        }
    }
}
