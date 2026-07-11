import SwiftUI
import Observation
import JoeScreenKit

/// Observable holder for the cursors currently visible in one remote window (M6). The
/// RemoteWindowManager pushes updates; the overlay view observes.
@MainActor
@Observable
final class CursorOverlayModel {
    var cursors: [ParticipantID: NormalizedPoint] = [:]
}

/// Renders every remote participant's pointer over a shared window, each in its deterministic
/// `ParticipantColor`, positioned by normalized [0,1] coordinates mapped into the current view size
/// (spec §3.8). Local window resizing is a pure display transform — the normalized value is invariant.
struct CursorOverlay: View {
    let windowID: WindowID
    let size: CGSize
    /// The video's aspect ratio, so an inbound cursor maps through the SAME letterbox content rect
    /// the sender used — pointer tips align on the same pixel feature at both ends (M9 fix). Nil ⇒
    /// fall back to the view rect (pre-M9 behavior) until dimensions are known.
    let videoAspect: Double?
    @Environment(CursorOverlayModel.self) private var overlayModel
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(overlayModel.cursors.keys), id: \.self) { participant in
                if let point = overlayModel.cursors[participant] {
                    CursorPointer(color: model.color(for: participant))
                        .position(position(for: point))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func position(for point: NormalizedPoint) -> CGPoint {
        if let aspect = videoAspect, aspect > 0 {
            return VideoFitMath.viewPoint(fromNormalized: point, videoAspect: aspect, viewSize: size)
        }
        return CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

/// A simple pointer glyph tinted to a participant's color.
struct CursorPointer: View {
    let color: Color
    var body: some View {
        Image(systemName: "cursorarrow.fill")
            .font(.system(size: 18))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.4), radius: 1, x: 0.5, y: 1)
    }
}
