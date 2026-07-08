import Foundation

/// Which media path a session is running on — surfaced in the UI so users understand latency and
/// trust characteristics (spec R25: server mode hairpins through the VPS and adds RTT; LAN mesh
/// meets the ≤150 ms ideal). This is a pure model consumed by the SwiftUI chrome; the full views
/// (SessionView, RosterView, RemoteWindowChromeView, CursorOverlayRenderer, …) live alongside in
/// this target and depend on JoeScreenKit's models.
public enum SessionMode: String, Sendable, Equatable {
    /// Star through the self-hosted LiveKit SFU (the default for all internet sessions — D4).
    case viaServer
    /// Feature-flagged serverless LAN mesh (≤3 co-located peers) — shipped dark in v1.
    case localNetwork

    public var displayLabel: String {
        switch self {
        case .viaServer:    return "via server"
        case .localNetwork: return "local network"
        }
    }

    /// Whether this mode can meet the ≤150 ms LAN glass-to-glass ideal.
    public var meetsLANLatencyIdeal: Bool { self == .localNetwork }
}

/// Capacity state surfaced by `AdmissionController` decisions, for the "you can share N more" /
/// "session at capacity for live sharing" UI (spec §3.2 / F7).
public enum ShareCapacityState: Equatable, Sendable {
    case canShareMore(remaining: Int)
    case atCapacity(reason: String)
}
