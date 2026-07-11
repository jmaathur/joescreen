import Foundation

/// The replicated annotation store for draw mode (F9). Holds every participant's strokes per
/// shared window and applies the three draw wire messages (`DrawOp`/`DrawClear`/`DrawUndo`)
/// under the draw channel's contract: reliable, **ordered per author** (spec §3.2 matrix —
/// cross-author order is irrelevant and never enforced).
///
/// Convergence argument: each author's ops arrive reliably and in authorSeq order, and every
/// mutation here is a function of (current state, one op) that commutes across authors — so all
/// peers that have seen the same per-author prefixes hold identical state, regardless of
/// cross-author interleaving. `apply(_:)` is still defensive about duplicates/stale seqs (e.g.
/// replay after a transport reconnect): a non-increasing `authorSeq` is dropped, not re-applied.
///
/// Pure value type: rendering (a stroke overlay view) observes this model; nothing here touches
/// a framework. Codable so a host can snapshot annotations for late joiners.
///
/// // TODO(Phase2): wire to the draw data channel — decode via WireCodec, apply here, publish
/// // per-window change notifications to the overlay renderer in JoeScreenUI.
public struct DrawModel: Codable, Sendable, Equatable {

    /// Outcome of applying one `DrawOp`.
    public enum ApplyResult: Sendable, Equatable {
        case applied
        /// The op's `authorSeq` did not advance the author's stream in this window (duplicate or
        /// reordered replay) and was dropped.
        case rejectedStaleSequence(lastApplied: UInt64)
    }

    /// window → author → strokes in ascending `authorSeq` order (append-only under the
    /// monotonicity check, so the invariant holds by construction).
    private var strokesByWindow: [WindowID: [ParticipantID: [DrawOp]]]

    /// window → author → highest `authorSeq` ever applied. Kept SEPARATE from the stroke arrays
    /// so clear/undo don't reset duplicate protection (a replayed old op after a clear must
    /// still be rejected, not resurrect ink the author deleted).
    private var highestSeqByWindow: [WindowID: [ParticipantID: UInt64]]

    public init() {
        self.strokesByWindow = [:]
        self.highestSeqByWindow = [:]
    }

    // MARK: - Applying wire messages

    /// Append a stroke iff it strictly advances its author's sequence in this window.
    @discardableResult
    public mutating func apply(_ op: DrawOp) -> ApplyResult {
        if let last = highestSeqByWindow[op.windowID]?[op.authorID], op.authorSeq <= last {
            return .rejectedStaleSequence(lastApplied: last)
        }
        highestSeqByWindow[op.windowID, default: [:]][op.authorID] = op.authorSeq
        strokesByWindow[op.windowID, default: [:]][op.authorID, default: []].append(op)
        return .applied
    }

    /// Remove ALL of one author's strokes in one window (an author clears only their own ink).
    public mutating func apply(_ clear: DrawClear) {
        strokesByWindow[clear.windowID]?[clear.authorID] = nil
        if strokesByWindow[clear.windowID]?.isEmpty == true {
            strokesByWindow[clear.windowID] = nil
        }
    }

    /// Remove the author's MOST RECENT stroke (highest `authorSeq`) in one window. Repeated
    /// undos peel back further; undo with nothing left is a no-op.
    public mutating func apply(_ undo: DrawUndo) {
        guard var authorStrokes = strokesByWindow[undo.windowID]?[undo.authorID],
              !authorStrokes.isEmpty else { return }
        authorStrokes.removeLast()
        strokesByWindow[undo.windowID]?[undo.authorID] = authorStrokes.isEmpty ? nil : authorStrokes
        if strokesByWindow[undo.windowID]?.isEmpty == true {
            strokesByWindow[undo.windowID] = nil
        }
    }

    // MARK: - Housekeeping

    /// Drop everything for a window (its share ended). Also forgets sequence watermarks — window
    /// IDs are never reused, so there is nothing left to protect.
    public mutating func removeWindow(_ window: WindowID) {
        strokesByWindow[window] = nil
        highestSeqByWindow[window] = nil
    }

    /// Drop a departed participant's ink everywhere (roster remove).
    public mutating func removeAuthor(_ author: ParticipantID) {
        for window in Array(strokesByWindow.keys) {
            strokesByWindow[window]?[author] = nil
            if strokesByWindow[window]?.isEmpty == true { strokesByWindow[window] = nil }
        }
        for window in Array(highestSeqByWindow.keys) {
            highestSeqByWindow[window]?[author] = nil
            if highestSeqByWindow[window]?.isEmpty == true { highestSeqByWindow[window] = nil }
        }
    }

    // MARK: - Queries

    /// All strokes to render for one window. The wire protocol leaves cross-author z-order
    /// unspecified (`orderedPerAuthor`), so we impose a DETERMINISTIC one — (authorSeq, authorID)
    /// — purely so every peer renders identical overlays.
    public func strokes(in window: WindowID) -> [DrawOp] {
        guard let byAuthor = strokesByWindow[window] else { return [] }
        return byAuthor.values.flatMap { $0 }.sorted {
            if $0.authorSeq != $1.authorSeq { return $0.authorSeq < $1.authorSeq }
            return $0.authorID.uuidString < $1.authorID.uuidString
        }
    }

    /// One author's strokes in one window, in authorSeq order.
    public func strokes(by author: ParticipantID, in window: WindowID) -> [DrawOp] {
        strokesByWindow[window]?[author] ?? []
    }

    public func strokeCount(in window: WindowID) -> Int {
        strokesByWindow[window]?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    /// Whether there is no ink anywhere (for the late-joiner seed guard).
    public var isEmpty: Bool { strokesByWindow.isEmpty }
}
