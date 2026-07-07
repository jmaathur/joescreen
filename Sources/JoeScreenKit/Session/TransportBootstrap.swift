import Foundation

/// The media-plane bootstrap SharePlay carries over its coordination channel (spec §3.1 / D9 / M7):
/// the LiveKit server URL, the room name, and a JWT. This is the ONLY media-related thing that ever
/// rides `GroupSessionMessenger` — media itself NEVER does (landmine #1). It's small (well under the
/// ≤200 KB messenger budget) and sent via `SignalingSendQueue` with retry/backoff (R10).
///
/// Defined in JoeScreenKit (pure) so it's Codable/round-trippable and testable without GroupActivities.
public struct TransportBootstrap: Codable, Sendable, Equatable {
    /// The LiveKit SFU URL to dial (wss:// in production).
    public var serverURL: URL
    /// The room name all participants of this SharePlay session share.
    public var roomName: String
    /// The per-participant JWT (from `infra/token-server`). Each participant fetches its OWN token
    /// keyed to its identity; the host may relay the server URL + room and let joiners fetch, or
    /// carry a token — this field holds whichever the host chose to send.
    public var jwt: String

    public init(serverURL: URL, roomName: String, jwt: String) {
        self.serverURL = serverURL
        self.roomName = roomName
        self.jwt = jwt
    }
}

/// The messages JoeScreen sends over `GroupSessionMessenger` (all coordination-plane, all small):
/// the transport bootstrap and periodic room-state snapshots for late joiners. Kept here so the
/// wire shape is testable without GroupActivities; the app's `GroupSessionCoordinator` encodes/decodes
/// these and hands them to `SignalingSendQueue`.
public enum CoordinationMessage: Codable, Sendable, Equatable {
    /// The host's media-plane bootstrap (sent to each joiner, re-sent to late joiners).
    case bootstrap(TransportBootstrap)
    /// A full room-state snapshot (revision-gated last-writer-wins), re-broadcast to late joiners so
    /// they catch up without waiting for the next change (R28).
    case roomSnapshot(RoomModel)

    // Explicit coding so the enum's wire shape is stable and small.
    enum CodingKeys: String, CodingKey { case kind = "k", bootstrap = "b", snapshot = "s" }
    enum Kind: String, Codable { case bootstrap, roomSnapshot }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .bootstrap:    self = .bootstrap(try c.decode(TransportBootstrap.self, forKey: .bootstrap))
        case .roomSnapshot: self = .roomSnapshot(try c.decode(RoomModel.self, forKey: .snapshot))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bootstrap(let b):
            try c.encode(Kind.bootstrap, forKey: .kind)
            try c.encode(b, forKey: .bootstrap)
        case .roomSnapshot(let m):
            try c.encode(Kind.roomSnapshot, forKey: .kind)
            try c.encode(m, forKey: .snapshot)
        }
    }

    /// Encode to wire bytes with the deterministic wire encoder.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> CoordinationMessage {
        try JSONDecoder().decode(CoordinationMessage.self, from: data)
    }
}
