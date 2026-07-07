import Foundation

/// Stable identifier for a participant on the wire. Mirrors the SharePlay `Participant.id` (an
/// opaque UUID — the only identity SharePlay exposes, per verified API facts) but is defined here
/// so JoeScreenKit stays free of the GroupActivities import.
public typealias ParticipantID = UUID

/// Stable identifier for a shared window (owner-assigned, unique within a session).
public typealias WindowID = UUID

/// The versioned wrapper for EVERY media-plane data-channel payload.
///
/// Wire shape: `{ version, kind, senderID, seq?, body }`.
/// - `version` lets the receiver reject/adapt to protocol revisions.
/// - `kind` selects the payload type AND (via `MessageKind.channel`) fixes the channel it must
///   have arrived on; a receiver can assert `kind.channel == channelItArrivedOn`.
/// - `seq` is present exactly for kinds whose channel requires it (the strictly-ordered `input`
///   channel); enforced by `validate()`.
/// - `body` is the opaque encoded payload; decoding is done by the kind-specific type.
///
/// Forward compatibility: an unknown `kind` raw value decodes to a `.unknownKind` envelope
/// rather than throwing, so a newer peer's messages are SKIPPED, not fatal (spec §wire-protocol).
public struct Envelope: Sendable, Equatable {
    /// Current protocol version. Bump on any breaking wire change.
    public static let currentVersion: UInt8 = 1

    public var version: UInt8
    /// `nil` when the wire tag was not recognized by this build (unknown-kind tolerance).
    public var kind: MessageKind?
    /// The raw wire tag, retained even when `kind == nil`, for logging/telemetry.
    public var rawKind: UInt16
    public var senderID: ParticipantID
    /// Monotonic per-sender sequence, present iff `kind?.policy.requiresSequence == true`.
    public var seq: UInt64?
    public var body: Data

    public init(
        version: UInt8 = Envelope.currentVersion,
        kind: MessageKind,
        senderID: ParticipantID,
        seq: UInt64? = nil,
        body: Data
    ) {
        self.version = version
        self.kind = kind
        self.rawKind = kind.rawValue
        self.senderID = senderID
        self.seq = seq
        self.body = body
    }

    /// Whether this envelope's raw tag was understood by this build.
    public var isKnownKind: Bool { kind != nil }

    public enum ValidationError: Error, Equatable {
        case unknownKind(UInt16)
        case missingSequence(MessageKind)
        case unexpectedSequence(MessageKind)
        case unsupportedVersion(UInt8)
    }

    /// Enforces the structural invariants a well-formed envelope must satisfy for a KNOWN kind:
    /// version supported, and `seq` present exactly when the kind's channel requires it.
    /// Unknown kinds are the caller's decision to skip (they are not "invalid", just unreadable).
    public func validate() throws {
        guard version == Envelope.currentVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        guard let kind else { throw ValidationError.unknownKind(rawKind) }
        let requiresSeq = kind.policy.requiresSequence
        if requiresSeq && seq == nil { throw ValidationError.missingSequence(kind) }
        if !requiresSeq && seq != nil { throw ValidationError.unexpectedSequence(kind) }
    }
}

// MARK: - Codec

extension Envelope: Codable {
    // Explicit keys so the on-wire JSON is stable regardless of property order.
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case rawKind = "k"
        case senderID = "s"
        case seq = "q"
        case body = "b"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(UInt8.self, forKey: .version)
        rawKind = try c.decode(UInt16.self, forKey: .rawKind)
        // Unknown-kind tolerance: an unrecognized tag yields kind == nil, NOT a decode failure.
        kind = MessageKind(rawValue: rawKind)
        senderID = try c.decode(ParticipantID.self, forKey: .senderID)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq)
        body = try c.decode(Data.self, forKey: .body)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(rawKind, forKey: .rawKind)
        try c.encode(senderID, forKey: .senderID)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encode(body, forKey: .body)
    }
}

// MARK: - Typed payload helpers

/// A payload type that knows which `MessageKind` (and therefore channel) it belongs to.
/// This is the seam that makes "cursor payload on the input channel" impossible to express:
/// packing always routes via `WireCodec.pack`, which reads `kind` from the payload type.
/// `Equatable` is required so round-trip tests and latest-wins/dedup logic can compare payloads.
public protocol WireMessage: Codable, Sendable, Equatable {
    static var kind: MessageKind { get }
}
