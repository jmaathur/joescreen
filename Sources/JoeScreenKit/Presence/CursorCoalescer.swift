import Foundation

/// Pure coalescing + latest-wins logic for the cursor channel (spec §3.8 / M6). Separated from the
/// runtime pump so it's unit-tested without a transport or a clock.
///
/// Outbound: cursor moves arrive faster than we should send (mouse events can burst well past 60 fps);
/// `CursorCoalescer` keeps only the LATEST move per window and emits at most one per window per flush
/// tick (~60 fps upstream). Coalescing is correct because cursor position is idempotent imagery, never
/// state — an intermediate position that's already superseded is worthless (spec §3.2).
///
/// Inbound: latest-wins by timestamp per (sender, window) — a move that arrives with an OLDER
/// timestamp than the last accepted one for that pair is stale (reordered on the unreliable channel)
/// and dropped.
public struct CursorCoalescer: Sendable {

    // MARK: - Outbound coalescing

    /// Latest pending move per window, replacing any earlier pending move for the same window.
    private var pending: [WindowID: CursorMove] = [:]

    public init() {}

    /// Record a local cursor move; supersedes any earlier un-flushed move for the same window.
    public mutating func offerOutbound(_ move: CursorMove) {
        // Keep the newest by timestamp (guards against out-of-order local sampling).
        if let existing = pending[move.windowID], existing.timestamp > move.timestamp { return }
        pending[move.windowID] = move
    }

    /// Whether there is anything pending to flush.
    public var hasPending: Bool { !pending.isEmpty }

    public var pendingCount: Int { pending.count }

    /// Drain the pending coalesced moves (at most one per window) and clear the buffer. The caller
    /// sends these on the cursor channel and calls this again on the next ~60 fps tick.
    public mutating func flushOutbound() -> [CursorMove] {
        let moves = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        return moves
    }

    // MARK: - Inbound latest-wins

    /// Last accepted inbound timestamp per (sender, window). Older arrivals are dropped as stale.
    private var lastInboundTimestamp: [Key: Double] = [:]
    private struct Key: Hashable { let sender: ParticipantID; let window: WindowID }

    /// Offer an inbound move from `sender`. Returns true if it should be applied (newer than the last
    /// accepted for this sender+window), false if it's stale (reordered on the unreliable channel).
    public mutating func acceptInbound(sender: ParticipantID, move: CursorMove) -> Bool {
        let key = Key(sender: sender, window: move.windowID)
        if let last = lastInboundTimestamp[key], move.timestamp <= last { return false }
        lastInboundTimestamp[key] = move.timestamp
        return true
    }

    /// Forget a sender's inbound state (e.g. on leave) so a rejoin re-baselines.
    public mutating func forgetInbound(_ sender: ParticipantID) {
        lastInboundTimestamp = lastInboundTimestamp.filter { $0.key.sender != sender }
    }
}
