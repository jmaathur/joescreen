import Foundation

/// Splits an oversize reliable-channel payload into ≤`maxChunkBytes` frames and reassembles them on
/// the receiver (spec §3 / M0). LiveKit's data-publish limit is **~15 KB per message** (NOT the
/// messenger's 256 KB), so clipboard images/RTF and large snapshots must be framed before they hit
/// `WireDataChannel.send`. Cursor/unreliable payloads are never chunked — reassembly needs reliable,
/// ordered delivery, which only the reliable channels provide.
///
/// Wire framing per chunk: `{ groupID, index, count, payload }`, JSON keys `g/i/n/p`. The `groupID`
/// ties fragments of one logical message together; `index`/`count` order and bound them. A chunk is
/// itself a `WireMessage`-free value carried inside the channel's byte stream — the transport adapter
/// calls `Chunker.split` before `send` and feeds every received frame into a `Reassembler`.
///
/// Pure/deterministic and fully unit-tested; no transport, no clock.
public enum Chunker {

    /// One fragment of a chunked payload. `Equatable` for round-trip tests.
    public struct Chunk: Codable, Sendable, Equatable {
        /// Groups fragments of one logical message. Unique per split call.
        public var groupID: UUID
        /// 0-based position of this fragment within its group.
        public var index: Int
        /// Total number of fragments in the group. A `count == 1` chunk is a whole small message.
        public var count: Int
        /// The raw bytes of this fragment.
        public var payload: Data

        public init(groupID: UUID, index: Int, count: Int, payload: Data) {
            self.groupID = groupID; self.index = index; self.count = count; self.payload = payload
        }

        enum CodingKeys: String, CodingKey {
            case groupID = "g"
            case index = "i"
            case count = "n"
            case payload = "p"
        }
    }

    /// Conservative default fragment ceiling (bytes) for the LiveKit ~15 KB data limit, leaving
    /// headroom for the chunk's own JSON envelope overhead (groupID/index/count + base64 expansion).
    /// The transport adapter passes the encoded-chunk budget, not the raw-payload budget: base64
    /// inflates bytes ~4/3, so keep the RAW slice well under 15 KB.
    public static let defaultMaxChunkBytes = 10_000

    /// A deterministic encoder for chunk frames (sorted keys → byte-stable round-trips in tests).
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    /// Split `data` into fragments of at most `maxChunkBytes` RAW bytes each, all sharing one fresh
    /// `groupID`. An empty input yields a single empty chunk (`count == 1`) so the receiver still
    /// reconstructs an empty message rather than nothing.
    ///
    /// - Parameter groupID: the group identifier; defaults to a fresh `UUID()`. Injectable so
    ///   deterministic tests can pin it.
    public static func split(
        _ data: Data,
        maxChunkBytes: Int = defaultMaxChunkBytes,
        groupID: UUID = UUID()
    ) -> [Chunk] {
        precondition(maxChunkBytes > 0, "maxChunkBytes must be positive")

        guard !data.isEmpty else {
            return [Chunk(groupID: groupID, index: 0, count: 1, payload: Data())]
        }

        // Ceil-divide the byte count into fragments.
        let count = (data.count + maxChunkBytes - 1) / maxChunkBytes
        var chunks: [Chunk] = []
        chunks.reserveCapacity(count)
        var index = 0
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: maxChunkBytes, limitedBy: data.endIndex) ?? data.endIndex
            // Re-base the slice to a standalone Data so its indices are 0-based on the wire.
            let slice = Data(data[offset..<end])
            chunks.append(Chunk(groupID: groupID, index: index, count: count, payload: slice))
            index += 1
            offset = end
        }
        return chunks
    }

    /// Encode a chunk to its wire bytes (what actually rides `WireDataChannel.send`).
    public static func encode(_ chunk: Chunk) throws -> Data {
        try makeEncoder().encode(chunk)
    }

    /// Decode a received wire frame back into a `Chunk`.
    public static func decode(_ data: Data) throws -> Chunk {
        try makeDecoder().decode(Chunk.self, from: data)
    }

    /// Convenience: is a raw payload small enough to send as a single unchunked frame? Callers can
    /// skip the group/index/count overhead for the common small-message case.
    public static func fitsInOneChunk(_ data: Data, maxChunkBytes: Int = defaultMaxChunkBytes) -> Bool {
        data.count <= maxChunkBytes
    }

    /// Reassembles chunks of one or more concurrent groups back into whole payloads. A `state`/
    /// `clipboard` receiver feeds every decoded `Chunk` in; a group completes when all `count`
    /// fragments have arrived, at which point `offer` returns the concatenated bytes exactly once.
    ///
    /// Robust to: fragments arriving out of order within a group, interleaved groups, and duplicate
    /// fragments (idempotent). It does NOT time out partial groups — the reliable/ordered channel
    /// guarantees eventual delivery; a caller that wants a ceiling can `forget` a stale group.
    public struct Reassembler: Sendable {
        private struct Partial {
            var count: Int
            var fragments: [Int: Data]
        }
        private var groups: [UUID: Partial] = [:]

        public init() {}

        public enum OfferError: Error, Equatable {
            /// A later fragment declared a different total than an earlier one for the same group.
            case inconsistentCount(groupID: UUID, expected: Int, got: Int)
            /// An index outside `0..<count`.
            case indexOutOfRange(groupID: UUID, index: Int, count: Int)
        }

        /// Offer one received chunk. Returns the fully reassembled payload when this chunk completes
        /// its group (and drops the group's state); returns `nil` while the group is still partial.
        @discardableResult
        public mutating func offer(_ chunk: Chunk) throws -> Data? {
            guard chunk.count >= 1 else {
                throw OfferError.inconsistentCount(groupID: chunk.groupID, expected: 1, got: chunk.count)
            }
            guard chunk.index >= 0, chunk.index < chunk.count else {
                throw OfferError.indexOutOfRange(groupID: chunk.groupID, index: chunk.index, count: chunk.count)
            }

            // Single-fragment fast path (the common small-message case): no state kept.
            if chunk.count == 1 {
                groups[chunk.groupID] = nil
                return chunk.payload
            }

            var partial = groups[chunk.groupID] ?? Partial(count: chunk.count, fragments: [:])
            guard partial.count == chunk.count else {
                throw OfferError.inconsistentCount(
                    groupID: chunk.groupID, expected: partial.count, got: chunk.count)
            }
            partial.fragments[chunk.index] = chunk.payload // idempotent on duplicates

            guard partial.fragments.count == partial.count else {
                groups[chunk.groupID] = partial
                return nil
            }

            // Complete: concatenate in index order and drop the group.
            groups[chunk.groupID] = nil
            var assembled = Data()
            for i in 0..<partial.count { assembled.append(partial.fragments[i] ?? Data()) }
            return assembled
        }

        /// Number of groups currently mid-reassembly (for backpressure/telemetry).
        public var pendingGroupCount: Int { groups.count }

        /// Drop a group's partial state (e.g. a sender that left mid-message).
        public mutating func forget(_ groupID: UUID) { groups[groupID] = nil }
    }
}
