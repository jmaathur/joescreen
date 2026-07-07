import Foundation

/// Packs typed `WireMessage` payloads into `Envelope`s and back. This is the ONLY sanctioned way
/// to construct an outbound envelope, which is what guarantees the payload↔channel binding: the
/// kind (and thus channel + reliability/ordering) is read from the payload's own `Self.kind`, so
/// a caller can never mislabel a cursor move as input.
public enum WireCodec {
    /// A deterministic JSON encoder (sorted keys) so round-trips are byte-stable in tests.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        // Preserve UUID/Data exactly; JSONEncoder encodes Data as base64 by default which is
        // lossless for our binary payloads (clipboard bytes, terminal bytes).
        return e
    }

    static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    /// Pack a typed payload into an envelope on its correct channel.
    /// - Parameter seq: required iff `M.kind.policy.requiresSequence`; the caller (SequenceTracker
    ///   / send path) supplies the monotonic value. `pack` asserts the presence contract.
    public static func pack<M: WireMessage>(
        _ payload: M,
        sender: ParticipantID,
        seq: UInt64? = nil
    ) throws -> Envelope {
        let body = try makeEncoder().encode(payload)
        let env = Envelope(kind: M.kind, senderID: sender, seq: seq, body: body)
        try env.validate() // catches missing/spurious seq before it ever hits the wire
        return env
    }

    /// The channel an outbound payload of type `M` must be sent on.
    public static func channel<M: WireMessage>(for _: M.Type) -> DataChannel { M.kind.channel }

    /// Unpack a received envelope into a typed payload, verifying the kind matches.
    /// Throws `.unknownKind` for forward-compat skips and `.kindMismatch` if the envelope's kind
    /// isn't `M`.
    public static func unpack<M: WireMessage>(_ envelope: Envelope, as _: M.Type) throws -> M {
        guard let kind = envelope.kind else {
            throw Envelope.ValidationError.unknownKind(envelope.rawKind)
        }
        guard kind == M.kind else { throw UnpackError.kindMismatch(expected: M.kind, got: kind) }
        return try makeDecoder().decode(M.self, from: envelope.body)
    }

    public enum UnpackError: Error, Equatable {
        case kindMismatch(expected: MessageKind, got: MessageKind)
    }
}
