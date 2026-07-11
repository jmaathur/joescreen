import Foundation

/// Decides WHO may currently write to the shared PTY (spec F12 / backlog #12). A shared terminal has
/// ONE writer at a time (simultaneous input interleaves into gibberish — the same non-goal as the
/// single-active-controller lock for injection). The host owns the PTY and grants/rotates the writer
/// token, mirrored on the wire via `TerminalControl.writerID`. Pure logic so the arbitration is
/// unit-tested without a PTY; the host applies its decision, receivers display "X is typing".
///
/// Trust model: like input authorization (D12), the writer decision is made HOST-SIDE against trusted
/// local state — the `writerID` on the wire is DISPLAY-ONLY for peers. A peer that lies about being
/// the writer gains nothing: the host only forwards bytes from the peer it actually granted.
public struct WriterArbiter: Sendable, Equatable {
    /// The current writer, or `nil` if the PTY is free to take.
    public private(set) var writer: ParticipantID?

    public init(writer: ParticipantID? = nil) { self.writer = writer }

    /// Try to take the write token. Succeeds if free or already held by `p`; fails if someone else
    /// holds it (they must release first — no preemption).
    @discardableResult
    public mutating func take(_ p: ParticipantID) -> Bool {
        if writer == nil || writer == p { writer = p; return true }
        return false
    }

    /// Release the token iff `p` holds it. A hand-off is release-then-take by the next writer.
    public mutating func release(_ p: ParticipantID) {
        if writer == p { writer = nil }
    }

    /// Whether `p` may write right now (the host gate for forwarding PTY input).
    public func canWrite(_ p: ParticipantID) -> Bool {
        writer == p
    }

    /// Force-clear the token when the current writer disconnects (host-side cleanup).
    public mutating func writerDisconnected(_ p: ParticipantID) {
        if writer == p { writer = nil }
    }
}
