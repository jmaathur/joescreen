import Foundation

/// What kind of thing a share track carries: one macOS window, or a whole display (M11). The wire
/// name prefix distinguishes them (`window:` vs `display:`) so a receiver maps a track back to the
/// right viewer treatment. `WindowID` identity is shared across both kinds — a display share mints a
/// `WindowID` exactly like a window share, so RoomModel / cursors / the state channel are untouched
/// by construction when M11 adds `display:`.
public enum ShareKind: String, Codable, Sendable, Equatable, CaseIterable {
    case window
    case display
}

/// The single source of truth for encoding/decoding share track names (spec §3 track-name contract).
///
/// The window form is **byte-identical** to what `LiveKitTransport.trackName(for:)` produced before
/// this seam existed (`window:<WindowID uuid>`), so no receiver on the wire sees a change. The
/// display form (`display:<WindowID uuid>`) is **additive** (M11): an old receiver parses it, gets a
/// `nil` window, and ignores it — never crashing. This keeps the "extend, never break" rule (§2).
///
/// Pure logic, unit-tested against window / display / garbage inputs; the transport delegates its
/// naming to this so the contract has exactly one implementation.
public enum ShareTrackName {

    /// Encode a `(kind, windowID)` pair to its wire track name.
    public static func encode(kind: ShareKind, windowID: WindowID) -> String {
        "\(kind.rawValue):\(windowID.uuidString)"
    }

    /// The decoded shape of a recognized share track name.
    public struct Parsed: Sendable, Equatable {
        public let kind: ShareKind
        public let windowID: WindowID
        public init(kind: ShareKind, windowID: WindowID) {
            self.kind = kind
            self.windowID = windowID
        }
    }

    /// Decode a wire track name into `(kind, windowID)`. Returns `nil` for anything that isn't a
    /// recognized share name — a `.camera` track name, a future prefix this build doesn't know, or
    /// garbage. Callers MUST degrade gracefully on `nil` (parse nil → ignore), never crash.
    public static func decode(_ name: String) -> Parsed? {
        // Split on the FIRST colon only: the UUID never contains one, and this keeps the parse
        // total (a name with no colon, or an unknown prefix, simply yields nil).
        guard let colonIndex = name.firstIndex(of: ":") else { return nil }
        let prefix = String(name[name.startIndex..<colonIndex])
        guard let kind = ShareKind(rawValue: prefix) else { return nil }
        let rest = String(name[name.index(after: colonIndex)...])
        guard let uuid = UUID(uuidString: rest) else { return nil }
        return Parsed(kind: kind, windowID: uuid)
    }

    /// Convenience: just the `WindowID` of a recognized share name (either kind), or `nil`.
    public static func windowID(from name: String) -> WindowID? {
        decode(name)?.windowID
    }
}
