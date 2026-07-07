import Foundation

/// Per-sender monotonic sequence acceptance for the strictly-ordered `input` channel.
///
/// The owner injects discrete input in RECEIPT ORDER and must detect loss (a gap) and reject
/// out-of-order/duplicate arrivals BEFORE injection — otherwise a dropped keystroke or a
/// reordered mouse-up silently corrupts the remote session (spec §3.2 matrix). Each sender has an
/// independent stream, so one sender's gap never stalls another.
///
/// Sequences are `UInt64` and may start at any value; only monotonic *increase* is assumed.
public struct SequenceTracker: Sendable {
    /// Outcome of offering one message's (sender, seq) to the tracker.
    public enum Decision: Equatable, Sendable {
        /// The next expected message — accept and inject.
        case accept
        /// A duplicate or already-superseded seq — drop silently.
        case duplicate
        /// Arrived before an expected earlier seq — reject (never inject out of order).
        case outOfOrder(expected: UInt64, got: UInt64)
        /// Accepted, but a gap preceded it: `missing` seqs were lost. Caller may request resend
        /// or surface degraded input; the message itself is still accepted (we don't stall).
        case gap(missing: ClosedRange<UInt64>)
    }

    /// Last accepted seq per sender. Absent = no message seen yet from that sender.
    private var lastAccepted: [ParticipantID: UInt64] = [:]

    public init() {}

    /// Offer a received message. First message from a sender establishes the baseline and is
    /// accepted with no gap.
    public mutating func offer(sender: ParticipantID, seq: UInt64) -> Decision {
        guard let last = lastAccepted[sender] else {
            lastAccepted[sender] = seq
            return .accept
        }

        if seq == last &+ 1 {
            lastAccepted[sender] = seq
            return .accept
        }

        if seq <= last {
            // Already saw this or an earlier one: duplicate/superseded.
            return .duplicate
        }

        // seq > last + 1: a forward jump. We accept (don't stall the stream) but report the gap.
        // NOTE on interpretation: because we advance to `seq`, the missing range is
        // (last+1 ... seq-1). A later-arriving in-gap message will then read as `.duplicate`,
        // which is the correct call for a strictly-ordered channel (we already moved past it).
        let missing = (last &+ 1)...(seq &- 1)
        lastAccepted[sender] = seq
        return .gap(missing: missing)
    }

    /// Whether we've seen any message from `sender`.
    public func hasSeen(_ sender: ParticipantID) -> Bool { lastAccepted[sender] != nil }

    /// The last accepted seq for a sender, if any.
    public func lastSeq(for sender: ParticipantID) -> UInt64? { lastAccepted[sender] }

    /// Drop a sender's state (e.g. on leave) so a rejoin re-baselines cleanly.
    public mutating func forget(_ sender: ParticipantID) { lastAccepted[sender] = nil }
}

/// The complementary SENDER side: hands out monotonic seqs for outbound input on a channel.
public struct SequenceGenerator: Sendable {
    private var next: UInt64
    public init(start: UInt64 = 0) { self.next = start }
    public mutating func take() -> UInt64 {
        let v = next
        next &+= 1
        return v
    }
}
