import Foundation

/// Video codec identity (spec D5). VP9 is the single-window Mac default for small-text legibility;
/// H.264 (VideoToolbox low-latency, always hardware) is the structural fallback and the only iOS /
/// multi-window / whole-display codec.
public enum VideoCodec: String, Codable, Sendable, Equatable {
    case vp9
    case h264
}

/// The D5 fallback state machine: starts on VP9 for a single-window Mac share and makes a ONE-WAY
/// transition to H.264 under encoder pressure. There is deliberately NO automatic return to VP9
/// within a share session (hysteresis) — flapping the codec churns keyframes and wrecks legibility.
///
/// Pure logic: the platform feeds it measurements; it emits at most one transition + one
/// renegotiation request.
public struct CodecSelector: Sendable {

    public struct Thresholds: Sendable {
        /// Rolling p95 encode time over the window that trips a fallback (seconds).
        public var p95EncodeSecTrip: Double
        /// Sustained fps below this (with changed frames) for `cpuLimitedSecTrip` trips fallback.
        public var cpuLimitedFpsFloor: Double
        public var cpuLimitedSecTrip: Double
        public init(p95EncodeSecTrip: Double = 0.022,
                    cpuLimitedFpsFloor: Double = 15,
                    cpuLimitedSecTrip: Double = 10) {
            self.p95EncodeSecTrip = p95EncodeSecTrip
            self.cpuLimitedFpsFloor = cpuLimitedFpsFloor
            self.cpuLimitedSecTrip = cpuLimitedSecTrip
        }
    }

    /// Thermal pressure as reported by the platform (mirrors ProcessInfo.ThermalState).
    public enum ThermalState: Sendable, Equatable { case nominal, fair, serious, critical }

    public private(set) var current: VideoCodec
    private let thresholds: Thresholds
    /// Once we fall back, we stay (one-way within the session).
    private var fellBack: Bool = false

    /// - Parameter windowCount: shares of ≥2 windows (or a whole-display share) start on H.264
    ///   structurally and never attempt VP9 (trigger D).
    public init(windowCount: Int, wholeDisplay: Bool = false, thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
        if windowCount >= 2 || wholeDisplay {
            current = .h264
            fellBack = true // structural: no VP9 to fall back FROM, and none to return to
        } else {
            current = .vp9
        }
    }

    /// The reason a transition happened (for logging/telemetry/tests).
    public enum Trigger: Equatable, Sendable {
        case structuralMultiWindow  // D
        case p95EncodeTooHigh       // A
        case cpuLimitedLowFps       // B
        case thermalSerious         // C
    }

    /// The action the caller must take when a transition fires.
    public struct Transition: Equatable, Sendable {
        public let to: VideoCodec
        public let trigger: Trigger
        /// The caller must request a single debounced renegotiation and demand a keyframe.
        public let requiresRenegotiation: Bool
    }

    /// Feed the latest rolling measurements. Returns a `Transition` exactly once, on the first
    /// trigger; subsequent calls after fallback return `nil`.
    public mutating func evaluate(
        rollingP95EncodeSec: Double,
        sustainedFps: Double,
        sustainedLowFpsSeconds: Double,
        framesChanging: Bool,
        thermal: ThermalState
    ) -> Transition? {
        guard !fellBack, current == .vp9 else { return nil }

        if thermal == .serious || thermal == .critical {
            return fallback(trigger: .thermalSerious)
        }
        if rollingP95EncodeSec > thresholds.p95EncodeSecTrip {
            return fallback(trigger: .p95EncodeTooHigh)
        }
        if framesChanging,
           sustainedFps < thresholds.cpuLimitedFpsFloor,
           sustainedLowFpsSeconds >= thresholds.cpuLimitedSecTrip {
            return fallback(trigger: .cpuLimitedLowFps)
        }
        return nil
    }

    private mutating func fallback(trigger: Trigger) -> Transition {
        current = .h264
        fellBack = true
        return Transition(to: .h264, trigger: trigger, requiresRenegotiation: true)
    }
}
