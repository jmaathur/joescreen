import Foundation

/// Shared App Group identity for the host↔extension bridge (spec D11). The concrete group ID is a
/// placeholder wired to the TEAM_ID signing strategy — a human must register the App Group and
/// substitute the real identifier (see RISKS.md R2). Using the wrong ID silently breaks the bridge,
/// so it is defined in ONE place.
public enum AppGroup {
    /// Placeholder App Group identifier. Replace `TEAMID` / bundle prefix at signing time.
    /// Format Apple expects: `group.<reverse-dns>`.
    public static let identifier = "group.com.example.joescreen"

    /// Filename of the shared status record inside the group container.
    public static let statusFileName = "broadcast-status.json"

    /// Filename of the shared encoded-frame ring buffer backing store.
    public static let ringBufferFileName = "encoded-frames.ring"
}
