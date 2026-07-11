import Foundation

/// A framework-free classification of a remote track's SDK source, mirrored from the transport's
/// `RemoteTrackSourceKind` so `TrackClassifier` can be pure (JoeScreenKit, LiveKit-free). The
/// transport maps its LiveKit `Track.Source` into this at the call site.
public enum TrackSource: Sendable, Equatable {
    case camera
    case screenShareVideo
    case other
}

/// Routes a subscribed remote video track to its destination (M10). Pure logic so the precedence
/// rule is unit-tested exhaustively and the same decision is reproducible everywhere.
///
/// Precedence (verified against the plan §M10):
///  1. A **parseable share name** wins REGARDLESS of source — `window:<uuid>` / `display:<uuid>`
///     always route to the share window path. (A sharer's window track is `source .screenShareVideo`,
///     but classifying by NAME first is forward-compatible and robust to source-kind surprises.)
///  2. Else, `source == .camera` → a participant camera tile.
///  3. Else → ignore (an unknown/audio/forward-compat track the video path shouldn't touch).
public enum TrackClassifier {

    public enum Classification: Sendable, Equatable {
        case windowShare(WindowID)
        case camera
        case ignore
    }

    public static func classify(name: String, source: TrackSource) -> Classification {
        // (1) A parseable share name wins outright — window OR display kind.
        if let windowID = ShareTrackName.windowID(from: name) {
            return .windowShare(windowID)
        }
        // (2) Camera source (LiveKit names camera tracks "camera", which is NOT a share name).
        if source == .camera {
            return .camera
        }
        // (3) Anything else — ignore (forward-compatible: a future prefix parses nil here and is
        // dropped, never crashes).
        return .ignore
    }
}
