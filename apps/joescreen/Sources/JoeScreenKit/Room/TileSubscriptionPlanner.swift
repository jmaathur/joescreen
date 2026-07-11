import Foundation

/// Pure ordering + decode-budget planning for the participant tile strip (M10). Deterministic so
/// tiles never jump on churn (same inputs → same order) and the decode cap is unit-testable without
/// a live SFU.
///
/// Ordering: the SELF tile is always first; remotes follow, sorted by display name (lowercased) with
/// a UUID tiebreak so two peers with the same name still have a stable order.
///
/// Decode budget: a receiver can only decode so many video streams. Shares take PRIORITY (they're
/// the point of the app); cameras get whatever budget remains. A camera tile beyond the budget still
/// SHOWS (as an avatar) but is marked `decoded == false` so the UI parks it (no renderer attached →
/// adaptive-stream stops the SFU forwarding that stream). The cap counts DECODED video streams total.
public enum TileSubscriptionPlanner {

    /// One planned tile.
    public struct Tile: Sendable, Equatable {
        public let participant: ParticipantID
        public let isSelf: Bool
        /// Whether this tile's camera video may be decoded (within budget). When false, show an avatar
        /// even if a camera track exists, to respect the decode cap.
        public let decoded: Bool
        public init(participant: ParticipantID, isSelf: Bool, decoded: Bool) {
            self.participant = participant
            self.isSelf = isSelf
            self.decoded = decoded
        }
    }

    /// Plan the tile order + decode budget.
    /// - Parameters:
    ///   - selfID: the local participant (always the first tile; the self-preview is a local track,
    ///     not counted against the remote decode budget).
    ///   - remotes: remote participant IDs to place.
    ///   - displayName: name lookup for ordering (nil → orders after named peers, by UUID).
    ///   - hasRenderableCamera: whether a remote has a camera track that COULD be decoded (drives
    ///     whether it consumes budget; a peer with no camera never consumes budget).
    ///   - sharesDecoded: count of share-window streams already decoded (they have priority).
    ///   - maxDecodedStreams: total decoded-video budget (default 6; shares first, cameras next).
    public static func plan(
        selfID: ParticipantID?,
        remotes: [ParticipantID],
        displayName: (ParticipantID) -> String?,
        hasRenderableCamera: (ParticipantID) -> Bool,
        sharesDecoded: Int,
        maxDecodedStreams: Int = 6
    ) -> [Tile] {
        var tiles: [Tile] = []
        if let selfID { tiles.append(Tile(participant: selfID, isSelf: true, decoded: true)) }

        // Stable order: display name (lowercased) then UUID string. A nil name sorts as "" so unnamed
        // peers cluster first deterministically — the UUID tiebreak keeps them stable.
        let ordered = remotes.sorted { l, r in
            let ln = (displayName(l) ?? "").lowercased()
            let rn = (displayName(r) ?? "").lowercased()
            if ln != rn { return ln < rn }
            return l.uuidString < r.uuidString
        }

        // Camera decode budget = total budget minus shares (priority), floored at 0.
        var cameraBudget = max(0, maxDecodedStreams - max(0, sharesDecoded))
        for id in ordered {
            let wantsCamera = hasRenderableCamera(id)
            let canDecode = wantsCamera && cameraBudget > 0
            if canDecode { cameraBudget -= 1 }
            tiles.append(Tile(participant: id, isSelf: false, decoded: canDecode))
        }
        return tiles
    }
}
