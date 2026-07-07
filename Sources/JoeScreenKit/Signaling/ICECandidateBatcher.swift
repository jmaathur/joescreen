import Foundation

/// A single ICE candidate on the wire (opaque SDP fragment + its media index).
public struct ICECandidate: Codable, Sendable, Equatable {
    public var sdpMid: String?
    public var sdpMLineIndex: Int32
    public var candidate: String
    public init(sdpMid: String?, sdpMLineIndex: Int32, candidate: String) {
        self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex; self.candidate = candidate
    }
}

/// A coalesced batch of candidates sent as ONE messenger message (LAN mesh mode only).
public struct ICEBatch: Codable, Sendable, Equatable {
    public var candidates: [ICECandidate]
    public var endOfCandidates: Bool
    public init(candidates: [ICECandidate], endOfCandidates: Bool) {
        self.candidates = candidates; self.endOfCandidates = endOfCandidates
    }
}

/// Coalesces trickle-ICE candidates so the LAN-mesh signaling path sends ONE batch per debounce
/// window instead of one messenger `send()` per candidate. This is the #1 defense against the
/// GroupSessionMessenger's undocumented burst-throttle (spec §3.1 / R10): the burst, not the size,
/// is what makes `send()` throw and silently drops candidates.
///
/// Pure/clock-injected: the caller supplies "now" (seconds) so tests are deterministic (Date.now()
/// isn't available in workflow scripts, and injectable time is better for unit tests anyway).
public struct ICECandidateBatcher: Sendable {
    private let debounce: Double
    private var pending: [ICECandidate] = []
    private var firstPendingAt: Double?
    private var flushedEnd = false

    /// - Parameter debounceSeconds: how long to accumulate candidates before a batch is "due".
    public init(debounceSeconds: Double = 0.15) { self.debounce = debounceSeconds }

    /// Add a candidate. Returns a batch to send NOW only if the debounce window has already
    /// elapsed since the first pending candidate (caller also calls `flushIfDue`/`flushEnd`).
    public mutating func add(_ c: ICECandidate, now: Double) -> ICEBatch? {
        pending.append(c)
        if firstPendingAt == nil { firstPendingAt = now }
        return flushIfDue(now: now)
    }

    /// Emit a batch if the debounce window elapsed. Call on a timer tick.
    public mutating func flushIfDue(now: Double) -> ICEBatch? {
        guard let start = firstPendingAt, now - start >= debounce, !pending.isEmpty else { return nil }
        return drain(end: false)
    }

    /// Force an immediate flush and mark end-of-candidates (gathering complete). This always emits
    /// a batch (even empty) carrying `endOfCandidates = true` so the peer knows gathering is done.
    public mutating func flushEnd() -> ICEBatch {
        flushedEnd = true
        return drain(end: true)
    }

    /// Whether an end-of-candidates batch has already been emitted (idempotency guard).
    public var didFlushEnd: Bool { flushedEnd }

    private mutating func drain(end: Bool) -> ICEBatch {
        let batch = ICEBatch(candidates: pending, endOfCandidates: end)
        pending.removeAll(keepingCapacity: true)
        firstPendingAt = nil
        return batch
    }

    /// Merge a received batch into an accumulator idempotently (dedup by candidate string+index).
    public static func merge(into set: inout [ICECandidate], batch: ICEBatch) {
        for c in batch.candidates where !set.contains(c) {
            set.append(c)
        }
    }
}
