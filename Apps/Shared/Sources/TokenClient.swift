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
    }

    /// Fetch a token for `identity` in `room`. `server` is the token-server base (e.g.
    /// https://token.example.com); the returned SFU URL comes from the server response.
    static func fetch(server: URL, room: String, identity: String) async throws -> String {
        var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)
        comps?.path = "/token"
        comps?.queryItems = [
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "identity", value: identity),
        ]
        guard let url = comps?.url else { throw TokenError.badBaseURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TokenError.httpStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.token.isEmpty else { throw TokenError.emptyToken }
        return decoded.token
    }
}
