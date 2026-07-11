import Foundation

/// The default server endpoint the app uses, so users don't have to know a URL.
///
/// - RELEASE: the production token server / SFU host (`https://sfu.cheffing.dev`), which serves BOTH
///   `/token` (the token server, co-hosted behind Caddy) and the LiveKit signaling. `TokenClient`
///   fetches a token there and dials the SFU URL the server returns.
/// - DEBUG: the local dev SFU (`ws://localhost:7880`), where `DevTokenMinter` mints a dev-key token
///   locally — no token server involved.
///
/// One constant so there's a single place to change the production endpoint.
public enum ServerConfig {
    #if DEBUG
    /// Local dev SFU (dialed directly; DevTokenMinter mints the token).
    public static let defaultServerString = "ws://localhost:7880"
    #else
    /// Production token-server base (co-hosted with the SFU). TokenClient fetches /token here and the
    /// server returns the wss:// SFU URL to dial.
    public static let defaultServerString = "https://sfu.cheffing.dev"
    #endif

    /// The default server URL, or nil if the string is somehow malformed.
    public static var defaultServerURL: URL? { URL(string: defaultServerString) }
}
