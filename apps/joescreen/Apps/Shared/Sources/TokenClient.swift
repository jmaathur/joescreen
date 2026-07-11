import Foundation

/// Fetches a production LiveKit JWT from `infra/token-server` (spec §1 / M7). The server holds the
/// real API secret; the client never embeds it. The endpoint is
/// `GET /token?room=<r>&identity=<participant-uuid>` → `{ token, url }` (matches infra/token-server/main.go).
///
/// In DEBUG the app mints tokens locally via `DevTokenMinter`; this client is the RELEASE path (and
/// the SharePlay-bootstrap path in M7 once the server URL is delivered over the messenger).
enum TokenClient {
    struct Response: Decodable {
        let token: String
        let url: String
    }

    enum TokenError: Error, Equatable {
        case badBaseURL
        case httpStatus(Int)
        case emptyToken
        /// The token server returned an SFU URL with an insecure (plaintext ws://) scheme — refused
        /// in Release so a misconfigured/compromised server can't silently downgrade media to plaintext.
        case insecureSFUScheme(String)
    }

    /// The resolved credentials for a join: the JWT plus the AUTHORITATIVE SFU URL the token server
    /// says to dial. The caller MUST dial `sfuURL` (not the token-server base) — in production the
    /// token server and SFU are generally different hosts, and the token server is the source of
    /// truth for where the SFU is.
    struct Credentials: Equatable {
        let token: String
        let sfuURL: URL
    }

    /// Fetch a token for `identity` in `room`. `server` is the token-server base (e.g.
    /// https://token.example.com — or the co-hosted https://sfu.example.com which serves /token too);
    /// the returned SFU URL comes from the server response. `name` (M10) is the optional display name
    /// → the server's JWT `name` claim → LiveKit `participant.name`.
    ///
    /// Returns BOTH the token and the SFU URL so the caller dials the right place (fixes the bug where
    /// the SFU URL the server returned was discarded and the token-server base was dialed instead).
    static func fetch(server: URL, room: String, identity: String, name: String? = nil) async throws -> Credentials {
        var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)
        comps?.path = "/token"
        // Normalize the FETCH scheme to http(s): `server` may arrive as ws:// / wss:// (that's how
        // DirectJoinParameters.serverURL is documented, e.g. from a joescreen:// deep link), but
        // URLSession.data(from:) only speaks http/https — ws/wss would fail with unsupportedURL. Map
        // wss→https, ws→http; leave http(s) as-is.
        switch comps?.scheme?.lowercased() {
        case "wss": comps?.scheme = "https"
        case "ws":  comps?.scheme = "http"
        default:    break
        }
        var items = [
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "identity", value: identity),
        ]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        comps?.queryItems = items
        guard let url = comps?.url else { throw TokenError.badBaseURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TokenError.httpStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.token.isEmpty else { throw TokenError.emptyToken }
        // The server tells us where the SFU is; fall back to the request host only if it omits it.
        let sfuURL = URL(string: decoded.url) ?? server
        // Refuse a plaintext SFU dial in Release: a misconfigured/compromised token server returning
        // ws:// / http:// would silently send all signaling + media negotiation in the clear (ATS is
        // disabled app-wide for the dev/LAN path). DEBUG keeps ws:// so the local dev SFU works.
        #if !DEBUG
        let scheme = sfuURL.scheme?.lowercased() ?? ""
        guard scheme == "wss" || scheme == "https" else { throw TokenError.insecureSFUScheme(scheme) }
        #endif
        return Credentials(token: decoded.token, sfuURL: sfuURL)
    }
}
