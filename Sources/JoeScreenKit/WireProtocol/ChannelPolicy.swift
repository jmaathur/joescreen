import Foundation

/// The media-plane data channels. Each has FIXED reliability/ordering semantics that are
/// OPPOSITE across channels — putting a keystroke on the cursor channel silently corrupts
/// the remote session (spec §3.2). This type is the single source of truth for that matrix.
public enum DataChannel: String, Codable, Sendable, CaseIterable {
    case cursor
    case input
    case clipboard
    case terminal
    case draw
}

/// Whether a channel guarantees delivery.
public enum Reliability: String, Codable, Sendable {
    /// Best-effort (WebRTC datagram / maxRetransmits=0). Latest-wins; never retransmit stale data.
    case unreliable
    /// Guaranteed delivery with retransmit (WebRTC reliable data channel).
    case reliable
}

/// Whether a channel preserves send order.
public enum Ordering: String, Codable, Sendable {
    /// No order guarantee; consumer resolves by timestamp/latest-wins.
    case unordered
    /// Strict receipt order across the whole channel.
    case ordered
    /// Ordered only within a single author's substream; cross-author order is irrelevant.
    case orderedPerAuthor
}

/// The per-channel reliability/ordering contract (spec §3.2 matrix). Immutable, total.
public struct ChannelPolicy: Sendable, Equatable {
    public let channel: DataChannel
    public let reliability: Reliability
    public let ordering: Ordering

    /// The one authoritative mapping. Any payload MUST be sent on the channel returned here for
    /// its `MessageKind` (see `MessageKind.channel`), never another.
    public static func policy(for channel: DataChannel) -> ChannelPolicy {
        switch channel {
        // Pointer moves ~60fps: latest-wins, coalesced, never retransmitted.
        case .cursor:    return ChannelPolicy(channel: .cursor,    reliability: .unreliable, ordering: .unordered)
        // Discrete input + capability grants: guaranteed + strict order + monotonic seq.
        case .input:     return ChannelPolicy(channel: .input,     reliability: .reliable,   ordering: .ordered)
        case .clipboard: return ChannelPolicy(channel: .clipboard, reliability: .reliable,   ordering: .ordered)
        case .terminal:  return ChannelPolicy(channel: .terminal,  reliability: .reliable,   ordering: .ordered)
        // Draw ink: reliable, ordered within each author's stroke stream.
        case .draw:      return ChannelPolicy(channel: .draw,      reliability: .reliable,   ordering: .orderedPerAuthor)
        }
    }

    /// True if this channel requires a monotonic per-sender sequence number on every message.
    /// Only the strictly-ordered `input` channel does (its loss/reorder detection depends on it).
    public var requiresSequence: Bool {
        channel == .input
    }
}
