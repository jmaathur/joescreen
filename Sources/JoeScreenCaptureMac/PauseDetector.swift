import Foundation

// This whole target is macOS-only in practice, but the PauseDetector is pure logic and compiles
// everywhere so it can be unit-tested on any host. No ScreenCaptureKit import here.

/// Mirrors SCFrameStatus outcomes we care about, decoupled from the SDK enum so this is testable
/// with synthetic timelines (the real Space-switch behavior is UNVERIFIED — R13).
public enum FrameStatus: Sendable, Equatable {
    case complete   // a real new frame was delivered
    case idle       // no change; content is static (NOT a pause)
    case blank      // blank frame
    case suspended  // stream reported suspended
}

/// Classifies capture frame-delivery gaps as PAUSE vs mere IDLE (spec §3.3 / D10 / R13).
///
/// The hazard: when a shared window leaves the active Space, ScreenCaptureKit *may* stop delivering
/// frames — but "no frames" is ambiguous with `.idle` (unchanged content). Treating a pause as a
/// disconnect would tear down the share; treating a real disconnect as idle would hang the peer's
/// view. Apple documents neither, so this is a runtime classifier fronted by a protocol, tuned per
/// OS version, not a hard-coded assumption.
public struct PauseDetector: Sendable {

    public enum State: Sendable, Equatable { case active, paused }

    /// If no `.complete` frame arrives for this long AND content was recently changing, classify
    /// as paused (seconds). Should be a small multiple of the stream's frame interval.
    private let pauseAfter: Double
    private var lastCompleteAt: Double?
    private var lastContentChangeAt: Double?
    private(set) public var state: State = .active

    public init(pauseAfterSeconds: Double = 1.0) { self.pauseAfter = pauseAfterSeconds }

    /// The classifier's transition, if any, so the caller can broadcast pause/resume once.
    public enum Transition: Sendable, Equatable { case didPause, didResume }

    /// Feed one observed frame status at time `now`. Returns a transition on edge, else nil.
    public mutating func observe(_ status: FrameStatus, now: Double) -> Transition? {
        switch status {
        case .complete:
            lastCompleteAt = now
            lastContentChangeAt = now
            if state == .paused {
                state = .active
                return .didResume
            }
            return nil

        case .idle:
            // Content is static; a long idle is NOT a pause. But if we were mid-motion and frames
            // then stopped entirely (the caller keeps calling observe on a timer with .idle/no
            // delivery), the time-based check below still applies via `tick`.
            return nil

        case .blank, .suspended:
            return maybePause(now: now)
        }
    }

    /// Call on a timer even when no frame arrives, so a total delivery stop (the Space-switch case)
    /// is detected purely by elapsed time since the last `.complete` frame.
    public mutating func tick(now: Double) -> Transition? {
        maybePause(now: now)
    }

    private mutating func maybePause(now: Double) -> Transition? {
        guard state == .active else { return nil }
        // Only consider it a pause if we had recent motion (otherwise it's just idle content).
        guard let lastChange = lastContentChangeAt else { return nil }
        let sinceComplete = now - (lastCompleteAt ?? lastChange)
        if sinceComplete >= pauseAfter {
            state = .paused
            return .didPause
        }
        return nil
    }
}
