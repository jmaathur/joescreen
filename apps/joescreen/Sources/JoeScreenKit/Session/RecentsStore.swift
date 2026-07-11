import Foundation

/// A bounded, deduped list of recently-joined sessions (spec F13 / backlog #5). Pure value logic so
/// add/dedup/cap/ordering is unit-tested; the app persists it (Codable) and drives the menu-bar
/// "Recent" list. Most-recent-first; re-joining an existing room moves it to the front (dedup by the
/// server+room key, NOT identity — identity is fresh per join).
public struct RecentsStore: Codable, Sendable, Equatable {

    /// One recent session. `identity` is intentionally NOT stored (fresh per join — the identity rule).
    public struct Entry: Codable, Sendable, Equatable {
        public let serverURL: String
        public let room: String
        public let displayName: String?
        public init(serverURL: String, room: String, displayName: String? = nil) {
            self.serverURL = serverURL
            self.room = room
            self.displayName = displayName
        }
        /// Dedup key: a session is "the same" when server + room match (identity varies per join).
        public var key: String { "\(serverURL)#\(room)" }
    }

    public private(set) var entries: [Entry]
    public let maxEntries: Int

    public init(entries: [Entry] = [], maxEntries: Int = 8) {
        self.maxEntries = max(1, maxEntries)
        // Enforce the cap + dedup on construction (defensive if decoded from a larger blob).
        self.entries = Self.deduped(entries, cap: self.maxEntries)
    }

    /// Record a join. Moves an existing (server, room) to the front (updating its display name),
    /// else prepends; caps to `maxEntries`. Most-recent-first.
    public mutating func record(_ entry: Entry) {
        var next = entries.filter { $0.key != entry.key } // drop any prior with the same key
        next.insert(entry, at: 0)
        entries = Array(next.prefix(maxEntries))
    }

    /// Remove a specific recent (user cleared it).
    public mutating func remove(key: String) {
        entries.removeAll { $0.key == key }
    }

    public mutating func clear() { entries = [] }

    /// Dedup keeping the FIRST occurrence (most recent), then cap.
    private static func deduped(_ entries: [Entry], cap: Int) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for e in entries where !seen.contains(e.key) {
            seen.insert(e.key)
            out.append(e)
            if out.count >= cap { break }
        }
        return out
    }
}
