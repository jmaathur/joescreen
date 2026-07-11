import Foundation

/// Every payload type carried on the media-plane data channels. The raw value is the wire tag;
/// it is a `UInt16` (not a Swift-synthesized ordinal) so reordering cases never renumbers the
/// wire, and unknown tags decode to `nil` for forward compatibility (see `Envelope`).
public enum MessageKind: UInt16, Codable, Sendable, CaseIterable {
    case cursorMove       = 1
    case inputEvent       = 2
    case capabilityGrant  = 3
    case capabilityRevoke = 4
    case clipboard        = 5
    case terminalData     = 6
    case terminalControl  = 7
    case drawOp           = 8
    case drawClear        = 9
    case drawUndo         = 10
    // M0 coordination-state additions. Tags 1–10 are reserved history; appending is the sanctioned
    // way to extend the protocol (never renumber existing tags).
    case roomSnapshot     = 11
    case shareEvent       = 12
    // F4 remote control: a participant's request to drive a window (rides the input channel so it
    // serializes with the input it gates). Appended — old peers decode nil and ignore.
    case controlRequest   = 13

    /// The channel this kind MUST travel on, per the §3.2 matrix. This is the compile-time link
    /// between a payload and its reliability/ordering guarantees: there is no way to name a kind
    /// without also fixing its channel.
    public var channel: DataChannel {
        switch self {
        case .cursorMove:
            return .cursor
        // Capability grants ride the SAME reliable/ordered channel as the input they authorize,
        // so a grant strictly precedes the first event it enables (spec wire-protocol table).
        case .inputEvent, .capabilityGrant, .capabilityRevoke, .controlRequest:
            return .input
        case .clipboard:
            return .clipboard
        case .terminalData, .terminalControl:
            return .terminal
        case .drawOp, .drawClear, .drawUndo:
            return .draw
        // Coordination-state kinds ride the reliable/ordered `state` channel (M0).
        case .roomSnapshot, .shareEvent:
            return .state
        }
    }

    /// Convenience: the full reliability/ordering contract for this kind.
    public var policy: ChannelPolicy { ChannelPolicy.policy(for: channel) }
}
