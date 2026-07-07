import Foundation
import CryptoKit

/// Local HS256 JWT minter for `livekit-server --dev` (IMPLEMENTATION_PROMPT §1). DEBUG-ONLY: it
/// embeds the well-known dev secret, which must NEVER ship in a release binary. Production tokens
/// come from `infra/token-server` via `TokenClient` (M7), which holds the real secret server-side.
///
/// Produces a STANDARD LiveKit access token, verified against docs.livekit.io auth docs and
/// cross-checked by diffing against `lk token create --api-key devkey --api-secret secret --join
/// --room demo --identity <id>`:
///   • header  `{"alg":"HS256","typ":"JWT"}`
///   • claims  `iss` = API key (`devkey`), `sub` = identity, `nbf` = now, `exp` = now + ttl,
///             and a `video` grant `{room, roomJoin:true, canPublish:true, canSubscribe:true,
///             canPublishData:true}`
///   • HMAC-SHA256 with the secret (`secret`); base64url WITHOUT padding on all three segments.
///
/// A rejected token fails M2/M4 with only an opaque auth error, so the claim shape here is exact.
#if DEBUG
public enum DevTokenMinter {
    /// livekit-server --dev well-known credentials (confirmed in server source).
    public static let devAPIKey = "devkey"
    public static let devAPISecret = "secret"

    /// Mint a dev JWT admitting `identity` into `room`.
    /// - Parameters:
    ///   - now: token issue time (nbf); `exp = now + ttl`. Injectable for deterministic tests.
    ///   - ttl: validity window in seconds (default 6h — comfortably longer than a demo session).
    public static func mint(
        identity: String,
        room: String,
        apiKey: String = devAPIKey,
        apiSecret: String = devAPISecret,
        now: Date = Date(),
        ttl: TimeInterval = 6 * 3600
    ) -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let nbf = Int(now.timeIntervalSince1970)
        let exp = Int(now.addingTimeInterval(ttl).timeIntervalSince1970)
        // The LiveKit `video` grant. Booleans must serialize as JSON true/false (not 1/0).
        let videoGrant: [String: Any] = [
            "room": room,
            "roomJoin": true,
            "canPublish": true,
            "canSubscribe": true,
            "canPublishData": true,
        ]
        let claims: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "nbf": nbf,
            "exp": exp,
            "video": videoGrant,
        ]

        let headerSegment = base64URLEncode(jsonData(header))
        let claimsSegment = base64URLEncode(jsonData(claims))
        let signingInput = "\(headerSegment).\(claimsSegment)"

        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let signatureSegment = base64URLEncode(Data(signature))

        return "\(signingInput).\(signatureSegment)"
    }

    // MARK: - Encoding

    /// Deterministic JSON serialization. `.sortedKeys` keeps the output stable so tests can diff it,
    /// and `.withoutEscapingSlashes` keeps `ws://` URLs / room names readable (JWT doesn't require
    /// escaped slashes; either is valid, but unescaped matches `lk`'s output more closely).
    private static func jsonData(_ obj: [String: Any]) -> Data {
        // JSONSerialization emits JSON `true`/`false` for NSNumber-bool bridged from Swift Bool, and
        // integers without decimal points for Int — exactly the LiveKit claim shape.
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// base64url WITHOUT padding (RFC 7515 §2): standard base64, `+`→`-`, `/`→`_`, strip `=`.
    private static func base64URLEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }
}
#endif
