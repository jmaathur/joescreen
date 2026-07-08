import Foundation

/// A transport-agnostic send queue that sits in front of GroupSessionMessenger (spec §3.1 / D9).
/// The messenger throws on oversize AND under burst (undocumented throttle), so this queue:
///  • chunks/validates against a conservative ≤200 KB limit (never hard-codes the transcript-only
///    256 KB cap as a protocol constant — R10),
///  • treats a `send` throw as "retry with backoff" rather than a lost message,
///  • applies BACKPRESSURE (bounded queue) instead of unbounded growth,
///  • preserves order of retried signaling.
///
/// It is pure/deterministic: it does not itself call the messenger. The owner drives it by pulling
/// the next ready item, attempting a send, and reporting success/failure back. Time is injected.
public struct SignalingSendQueue: Sendable {

    public struct Config: Sendable {
        /// Conservative per-message ceiling (bytes). Below the transcript-only 256 KB figure.
        public var maxMessageBytes: Int
        /// Max queued items before `enqueue` applies backpressure (rejects).
        public var maxDepth: Int
        /// Initial retry backoff (seconds), doubled per attempt up to `maxBackoff`.
        public var baseBackoff: Double
        public var maxBackoff: Double
        public var maxAttempts: Int
        public init(maxMessageBytes: Int = 200_000, maxDepth: Int = 256,
                    baseBackoff: Double = 0.1, maxBackoff: Double = 5.0, maxAttempts: Int = 8) {
            self.maxMessageBytes = maxMessageBytes; self.maxDepth = maxDepth
            self.baseBackoff = baseBackoff; self.maxBackoff = maxBackoff; self.maxAttempts = maxAttempts
        }
    }

    public struct Item: Sendable, Equatable {
        public let id: UInt64
        public var payload: Data
        public var attempts: Int
        public var nextEligibleAt: Double
        /// Optional per-peer key used to STAGGER handshakes: two items with the same peer key won't
        /// both be "ready" in the same tick (the second is delayed).
        public var peerKey: String?
    }

    public enum EnqueueError: Error, Equatable {
        case tooLarge(bytes: Int, limit: Int)
        case backpressure(depth: Int)
    }

    public enum SendOutcome: Sendable { case success, throttledRetry, permanentFailure }

    private var queue: [Item] = []
    private var nextID: UInt64 = 0
    private let config: Config
    /// Per-peer stagger: the earliest time the next same-peer item may become ready.
    private var peerReadyGate: [String: Double] = [:]
    /// Minimum spacing between two same-peer sends (seconds).
    private let peerStagger: Double

    public init(config: Config = Config(), peerStaggerSeconds: Double = 0.05) {
        self.config = config
        self.peerStagger = peerStaggerSeconds
    }

    public var depth: Int { queue.count }
    public var isEmpty: Bool { queue.isEmpty }

    /// Enqueue a signaling payload. Rejects oversize (before it ever throws at the messenger) and
    /// applies backpressure when the queue is full.
    @discardableResult
    public mutating func enqueue(_ payload: Data, peerKey: String? = nil, now: Double) throws -> UInt64 {
        guard payload.count <= config.maxMessageBytes else {
            throw EnqueueError.tooLarge(bytes: payload.count, limit: config.maxMessageBytes)
        }
        guard queue.count < config.maxDepth else {
            throw EnqueueError.backpressure(depth: queue.count)
        }
        let id = nextID; nextID &+= 1
        // Respect the per-peer stagger gate.
        var eligible = now
        if let key = peerKey, let gate = peerReadyGate[key], gate > eligible { eligible = gate }
        queue.append(Item(id: id, payload: payload, attempts: 0, nextEligibleAt: eligible, peerKey: peerKey))
        if let key = peerKey { peerReadyGate[key] = eligible + peerStagger }
        return id
    }

    /// Pull the next item whose backoff/stagger has elapsed, in FIFO order. Does not remove it —
    /// call `reportSuccess`/`reportFailure` after attempting the send.
    public func nextReady(now: Double) -> Item? {
        queue.first { $0.nextEligibleAt <= now }
    }

    /// The send succeeded: remove the item.
    public mutating func reportSuccess(_ id: UInt64) {
        queue.removeAll { $0.id == id }
    }

    /// The send threw (throttle/transient). Returns the outcome: retry (with a scheduled backoff)
    /// or permanent failure (attempts exhausted → dropped).
    @discardableResult
    public mutating func reportFailure(_ id: UInt64, now: Double) -> SendOutcome {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return .success }
        queue[idx].attempts += 1
        if queue[idx].attempts >= config.maxAttempts {
            queue.remove(at: idx)
            return .permanentFailure
        }
        let backoff = min(config.baseBackoff * pow(2, Double(queue[idx].attempts - 1)), config.maxBackoff)
        queue[idx].nextEligibleAt = now + backoff
        return .throttledRetry
    }
}
