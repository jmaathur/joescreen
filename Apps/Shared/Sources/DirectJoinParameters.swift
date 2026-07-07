import Foundation
import JoeScreenKit

/// Direct Session Mode join parameters (IMPLEMENTATION_PROMPT §1): the explicit
/// server-URL + room + identity a user (or automation) supplies to join a call WITHOUT SharePlay.
///
/// Three entry points all resolve to this one value:
///   • the join sheet (typed fields),
///   • a `joescreen://join?server=…&room=…&identity=…` deep link,
///   • launch arguments `--join-url ws://… --room … --identity …` (zero-click automation).
///
/// Identity rule (demo-critical): identity defaults to a FRESH `UUID()` per launch. LiveKit evicts
/// the previous holder when a duplicate identity joins, so two instances that shared a default
/// identity would silently kill instance A the moment B connects. `identity` here is the string form
/// that becomes the JWT `sub`; `participantID` parses it back to a `ParticipantID` (UUID) for the
/// media-plane identity binding. Non-UUID identities are allowed on the wire but yield a nil
/// `participantID` (the transport rejects unparseable identities per §3).
public struct DirectJoinParameters: Sendable, Equatable {
    /// The LiveKit SFU URL to dial (ws:// for --dev, wss:// for TLS).
    public var serverURL: URL
    /// Room name (all participants of one call share it).
    public var room: String
    /// Participant identity string — becomes the JWT `sub`. Defaults to a fresh UUID per launch.
    public var identity: String

    public init(serverURL: URL, room: String, identity: String = UUID().uuidString) {
        self.serverURL = serverURL
        self.room = room
        self.identity = identity
    }

    /// The identity parsed back to a `ParticipantID`, or `nil` if it isn't a UUID. The media plane
    /// binds identities to `ParticipantID`; a non-UUID identity can connect but can't be mapped to a
    /// participant for input-authorization purposes.
    public var participantID: ParticipantID? { UUID(uuidString: identity) }

    // MARK: - Launch arguments

    /// Parse `--join-url <url> --room <name> --identity <id>` from a launch argument vector. Returns
    /// nil when `--join-url` is absent (no direct-join requested — the app shows the join sheet).
    /// `--room` defaults to "demo" and `--identity` to a fresh UUID when omitted, so
    /// `--join-url ws://localhost:7880` alone is a valid zero-config join.
    public static func fromLaunchArguments(_ args: [String]) -> DirectJoinParameters? {
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--join-url", "--room", "--identity":
                // Support both "--flag value" and "--flag=value".
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    values[a] = args[i + 1]
                    i += 2
                    continue
                }
            default:
                if let eq = a.range(of: "="), a.hasPrefix("--") {
                    let key = String(a[a.startIndex..<eq.lowerBound])
                    if key == "--join-url" || key == "--room" || key == "--identity" {
                        values[key] = String(a[eq.upperBound...])
                    }
                }
            }
            i += 1
        }
        guard let urlString = values["--join-url"], let url = URL(string: urlString) else {
            return nil
        }
        let room = values["--room"] ?? "demo"
        let identity = values["--identity"] ?? UUID().uuidString
        return DirectJoinParameters(serverURL: url, room: room, identity: identity)
    }

    // MARK: - URL scheme

    /// Parse a `joescreen://join?server=<url>&room=<name>&identity=<id>` deep link. Also accepts
    /// `url=` as an alias for `server=`. Room/identity default as in the launch-argument path.
    public static func fromURL(_ url: URL) -> DirectJoinParameters? {
        guard url.scheme == "joescreen" else { return nil }
        // Accept both joescreen://join?… and joescreen:join?… shapes.
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // host is "join" for joescreen://join?…; be lenient if the path carries it instead.
        let isJoin = (comps.host == "join") || url.absoluteString.contains("join")
        guard isJoin else { return nil }
        let items = comps.queryItems ?? []
        func value(_ names: [String]) -> String? {
            for n in names { if let v = items.first(where: { $0.name == n })?.value, !v.isEmpty { return v } }
            return nil
        }
        guard let serverStr = value(["server", "url"]), let server = URL(string: serverStr) else {
            return nil
        }
        let room = value(["room"]) ?? "demo"
        let identity = value(["identity"]) ?? UUID().uuidString
        return DirectJoinParameters(serverURL: server, room: room, identity: identity)
    }

    /// Render a shareable `joescreen://join?…` deep link for this set of parameters (identity is
    /// intentionally OMITTED so each joiner gets a fresh UUID — see the identity rule above).
    public func shareableURL(includeIdentity: Bool = false) -> URL? {
        var comps = URLComponents()
        comps.scheme = "joescreen"
        comps.host = "join"
        var items = [
            URLQueryItem(name: "server", value: serverURL.absoluteString),
            URLQueryItem(name: "room", value: room),
        ]
        if includeIdentity { items.append(URLQueryItem(name: "identity", value: identity)) }
        comps.queryItems = items
        return comps.url
    }
}
