import Foundation
import JoeScreenKit

#if os(macOS)
import CoreMedia
import CoreVideo

/// Events surfaced by any share-capture service (window or display) to the app orchestrator (M11).
/// Extracted from `WindowCaptureService.Event` so both capture services + the shared stream bridge
/// speak one vocabulary.
public enum ShareCaptureEvent: Sendable {
    /// A `.complete` frame was captured and forwarded to the sink.
    case frame(count: Int)
    /// The capture pipeline paused (off-Space / suspended / screen-locked) — NOT a disconnect (R13).
    case paused
    /// The capture pipeline resumed delivering complete frames.
    case resumed
    /// The captured surface went away and the share should end (window minimized, display unplugged).
    case ended(reason: String)
    /// The source settled at a new PIXEL size after a resize / display-resolution change; the stream
    /// was reconfigured. The app re-broadcasts these dimensions in ShareInfo.
    case resized(pixelWidth: Int, pixelHeight: Int)
    /// The stream stopped with an error (SCStreamDelegate.didStopWithError).
    case stopped(reason: String)
}

/// The common surface `AppModel` needs from a share-capture service so it can hold
/// `[WindowID: any ShareCaptureService]` and treat window + display shares uniformly (M11). The
/// start method differs per service (a CGWindowID vs a CGDirectDisplayID), so it is NOT in the
/// protocol; everything downstream of start is.
public protocol ShareCaptureService: Actor {
    /// The JoeScreen window identity this capture publishes under.
    nonisolated var windowID: WindowID { get }
    /// Subscribe to capture events (call before start).
    func events() -> AsyncStream<ShareCaptureEvent>
    /// Stop capturing and tear down.
    func stop() async
    /// Advisory metadata captured at start (title/app/source pixels/kind). Nil before start.
    var shareInfo: ShareInfo? { get }
}

#endif
