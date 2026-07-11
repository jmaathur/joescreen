import ReplayKit
import LiveKit

/// The iOS Broadcast Upload Extension entry point for whole-screen sharing (backlog / iOS Phase 2).
///
/// iOS can only screen-share the WHOLE screen, via a ReplayKit broadcast extension (R6). LiveKit's
/// `LKSampleHandler` does all the heavy lifting: it reads ReplayKit sample buffers, pipes them over a
/// unix socket (in the shared App Group container) to the main app, where `BroadcastManager`
/// publishes them as a screen-share track. This subclass is a thin shell — the SDK is the engine.
///
/// Memory: the broadcast extension runs under a tight (~50 MB, R7) jetsam budget, so it links ONLY
/// LiveKit's broadcast path and does nothing heavy itself.
class SampleHandler: LKSampleHandler, @unchecked Sendable {
    // LKSampleHandler handles broadcastStarted / processSampleBuffer / broadcastFinished. We keep the
    // default behavior (publish the whole screen). Override points exist if we later want to filter.
    override var enableLogging: Bool { true }
}
