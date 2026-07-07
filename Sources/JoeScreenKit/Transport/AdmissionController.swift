import Foundation

/// Three-sided admission control (spec §3.2 / D4). Before a host adds a share, the app checks the
/// proposed load against measured limits and DEGRADES quality or REFUSES rather than silently
/// saturating the link. Pure math so it's unit-tested without a network.
///
/// The three sides:
///  1. Sharer uplink — Σ(shared-window bitrates) must fit within a safety fraction of measured up.
///     In SFU mode the host sends ONE copy per window (peer-count-independent). In mesh mode it
///     sends (N−1) copies, so the effective cost is multiplied.
///  2. Receiver decode — only VISIBLE remote windows are decoded; cap the simultaneous count.
///  3. Host encode — cap shared-windows-per-host at the measured max concurrent low-latency encode
///     sessions on a base Apple Silicon Mac (the Phase-0(f) constant).
public struct AdmissionController: Sendable {

    public enum Topology: Sendable, Equatable { case sfu, mesh }

    public struct Config: Sendable {
        /// Fraction of measured uplink we're willing to consume (spec: ~70%).
        public var uplinkSafetyFraction: Double
        /// Max concurrent low-latency encode sessions on this host (from Phase-0(f); conservative
        /// default of 1 assumes the single-hardware-encoder base-chip case until measured).
        public var maxEncodeSessions: Int
        /// Max simultaneously-decoded remote windows on a receiver.
        public var maxDecodedWindows: Int
        /// The lowest per-window bitrate we'll degrade to before refusing (bps).
        public var minPerWindowBitrate: Double

        public init(
            uplinkSafetyFraction: Double = 0.70,
            maxEncodeSessions: Int = 1,
            maxDecodedWindows: Int = 6,
            minPerWindowBitrate: Double = 800_000
        ) {
            self.uplinkSafetyFraction = uplinkSafetyFraction
            self.maxEncodeSessions = maxEncodeSessions
            self.maxDecodedWindows = maxDecodedWindows
            self.minPerWindowBitrate = minPerWindowBitrate
        }
    }

    /// The decision when a host asks to add one more shared window.
    public enum ShareDecision: Equatable, Sendable {
        /// Admit at the requested bitrate.
        case admit(bitrate: Double)
        /// Admit, but the WHOLE set must drop to this per-window bitrate to fit the uplink.
        case degrade(perWindowBitrate: Double)
        /// Refuse: even at the floor it won't fit, or the encode-session cap is hit.
        case refuseAtCapacity(reason: RefuseReason)
    }

    public enum RefuseReason: Equatable, Sendable {
        case encodeSessionCap(max: Int)
        case uplinkExhausted(availableBps: Double, floorNeedBps: Double)
    }

    private let config: Config
    public init(config: Config = Config()) { self.config = config }

    /// Decide whether a host can add one more shared window.
    /// - Parameters:
    ///   - currentWindowCount: windows already shared by this host.
    ///   - requestedBitrate: desired bitrate for the new window (bps).
    ///   - existingBitrate: current per-window bitrate of the already-shared windows (bps).
    ///   - measuredUplinkBps: measured available uplink (bps).
    ///   - peerCount: total session participants (used only for mesh multiplier).
    ///   - topology: SFU (1 copy) or mesh ((N−1) copies).
    public func admitShare(
        currentWindowCount: Int,
        requestedBitrate: Double,
        existingBitrate: Double,
        measuredUplinkBps: Double,
        peerCount: Int,
        topology: Topology
    ) -> ShareDecision {
        // Host encode cap first — a hard structural limit independent of bandwidth.
        if currentWindowCount + 1 > config.maxEncodeSessions {
            return .refuseAtCapacity(reason: .encodeSessionCap(max: config.maxEncodeSessions))
        }

        let copies = mediaCopies(peerCount: peerCount, topology: topology)
        let budget = measuredUplinkBps * config.uplinkSafetyFraction
        let newCount = currentWindowCount + 1

        // Best case: everyone stays at their bitrate. Total = copies × (existing×N + requested).
        let fullCost = copies * (existingBitrate * Double(currentWindowCount) + requestedBitrate)
        if fullCost <= budget {
            return .admit(bitrate: requestedBitrate)
        }

        // Degrade: find the uniform per-window bitrate that fits, clamped to the floor.
        // budget = copies × perWindow × newCount  ⇒  perWindow = budget / (copies × newCount).
        let perWindow = budget / (copies * Double(newCount))
        if perWindow >= config.minPerWindowBitrate {
            return .degrade(perWindowBitrate: perWindow)
        }

        // Even at the floor it won't fit.
        let floorNeed = copies * config.minPerWindowBitrate * Double(newCount)
        return .refuseAtCapacity(reason: .uplinkExhausted(availableBps: budget, floorNeedBps: floorNeed))
    }

    /// Whether a receiver can decode one more remote window (visible-only cap).
    public func canDecodeAnotherWindow(currentlyDecoded: Int) -> Bool {
        currentlyDecoded < config.maxDecodedWindows
    }

    private func mediaCopies(peerCount: Int, topology: Topology) -> Double {
        switch topology {
        case .sfu:  return 1.0
        case .mesh: return Double(max(peerCount - 1, 1))
        }
    }
}
