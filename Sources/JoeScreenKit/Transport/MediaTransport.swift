import Foundation

/// The media-plane seam (spec D3/D4/D7): everything real-time — per-window video tracks and the
/// five typed data channels — crosses this protocol. JoeScreenKit NEVER imports LiveKit; the one
/// concrete adapter (`LiveKitTransport`, app layer) owns the SDK so the R22 rule ("exactly one
/// libwebrtc in the process") is enforced by the dependency graph, and every consumer is testable
/// against a loopback fake.
///
/// // TODO(Phase2): app-layer `LiveKitTransport` adapter — connect via the token endpoint's JWT,
/// // map publish/unpublish to LiveKit track APIs, back data channels with LiveKit reliable/lossy
/// // data publish, honor visible-window-only selective subscription (dynacast/adaptive-stream).
/// // TODO(Phase2): loopback `FakeMediaTransport` in test support for end-to-end model tests.

/// Connection lifecycle of the media plane. Distinct from `SessionLifecycleState` (control
/// plane): SharePlay can be joined while the SFU link is still reconnecting, and the UI shows
/// both truthfully.
public enum MediaConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    /// Link dropped; the adapter is retrying with backoff. Published tracks resume on success.
    case reconnecting
    /// Terminal failure; a fresh `connect` is required. `reason` is diagnostic text for logs/UI.
    case failed(reason: String)
}

/// What a transport needs to reach the media plane. For the v1 LiveKit star this is the SFU URL
/// plus the JWT minted by the token endpoint; the feature-flagged LAN mesh mode reuses the same
/// shape with a local descriptor.
public struct MediaTransportConfiguration: Sendable, Equatable {
    public var serverURL: URL
    /// Signed token whose embedded identity MUST equal the `transportIdentity` later bound via
    /// `bindIdentity` — that equality is what ties media-plane traffic to a SharePlay participant.
    public var authToken: String

    public init(serverURL: URL, authToken: String) {
        self.serverURL = serverURL
        self.authToken = authToken
    }
}

/// An opaque platform video frame handed across the seam WITHOUT this package naming CoreVideo/
/// VideoToolbox types. The capture side boxes what it has (a `CVPixelBuffer`, or an encoded
/// sample for the pre-encoded iOS broadcast path); the adapter downcasts to what its SDK expects
/// and must reject boxes it doesn't recognize. Metadata rides alongside so admission/telemetry
/// never need to open the box.
public struct OpaqueVideoFrame: Sendable {
    /// The boxed platform frame. `any Sendable` keeps the struct Sendable while staying
    /// framework-free here.
    public var box: any Sendable
    /// Capture timestamp, nanoseconds, sender's monotonic clock.
    public var timestampNanos: UInt64
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(box: any Sendable, timestampNanos: UInt64, pixelWidth: Int, pixelHeight: Int) {
        self.box = box
        self.timestampNanos = timestampNanos
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Where captured frames for ONE published window track are submitted. Latest-wins: an adapter
/// under pressure may drop frames (video is idempotent imagery, never state — spec §3.2).
public protocol VideoFrameSink: Sendable {
    func submit(_ frame: OpaqueVideoFrame) async
}

/// One typed data channel, already configured with the reliability/ordering fixed by
/// `ChannelPolicy.policy(for: channel)`. Adapters MUST derive the underlying channel's settings
/// from that policy — never hand-pick them — so "keystrokes on the lossy channel" stays
/// unrepresentable (spec §3.2).
public protocol WireDataChannel: Sendable {
    var channel: DataChannel { get }
    /// Send one `WireCodec`-encoded `Envelope`. Throws on a dead/overflowed channel; unreliable
    /// channels may silently drop instead (their contract).
    func send(_ payload: Data) async throws
    /// Inbound payloads from all remote peers, in the order the channel's policy guarantees.
    func incoming() -> AsyncStream<Data>
}

/// The transport protocol itself. Implementations are reference types (actors) in the app layer.
public protocol MediaTransport: Sendable {

    /// Connect to the media plane. Resolves once `.connected`; throws on terminal failure.
    func connect(_ configuration: MediaTransportConfiguration) async throws

    /// Tear down tracks, channels, and the connection. Safe to call in any state.
    func disconnect() async

    /// Current connection state followed by every transition.
    func connectionStates() -> AsyncStream<MediaConnectionState>

    /// Bind a SharePlay participant to their media-plane identity (the identity string inside
    /// their JWT). Incoming tracks/data are attributed through this mapping — input authorization
    /// (spec §3.5: events must come from the authenticated peer) depends on it being correct.
    func bindIdentity(_ participantID: ParticipantID, transportIdentity: String) async

    /// Publish one video track for a shared window (one window == one track; the host sends ONE
    /// copy in SFU mode regardless of peer count). Caller must have passed `AdmissionController`
    /// first. Returns the sink capture feeds.
    func publishVideoTrack(for windowID: WindowID) async throws -> any VideoFrameSink

    /// Stop publishing a window's track (share ended or paused-long). Idempotent.
    func unpublishVideoTrack(for windowID: WindowID) async

    /// Open (or return the already-open) typed data channel for `channel`, configured per its
    /// `ChannelPolicy`.
    func openDataChannel(_ channel: DataChannel) async throws -> any WireDataChannel
}
