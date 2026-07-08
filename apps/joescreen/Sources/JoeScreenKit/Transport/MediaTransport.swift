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

/// A selectable capture device (a webcam, or an audio input) surfaced to the UI WITHOUT this
/// package naming AVFoundation / LiveKit device types. The adapter maps its SDK's device objects
/// to this shape; `id` is the adapter's stable device handle (an `AVCaptureDevice.uniqueID` for
/// cameras, a Core Audio device id for mics) and round-trips back through `selectAudioInput` /
/// `setCamera` to pick that exact device.
public struct MediaInputDevice: Sendable, Identifiable, Equatable {
    /// Adapter-stable device handle (camera `uniqueID` / audio `deviceId`). Opaque to the UI.
    public let id: String
    /// Human-readable device name for the picker (e.g. "FaceTime HD Camera").
    public let name: String
    /// Whether the OS considers this the current system-default device for its kind.
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Which family of input devices to enumerate. Output (speaker) selection is a separate concern
/// the UI doesn't expose yet, so it's intentionally absent.
public enum MediaDeviceKind: Sendable, Equatable {
    case audioInput
    case videoInput
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

    // MARK: - Local capture devices (mic + webcam)

    /// Enumerate the selectable input devices of `kind` (webcams or audio inputs). The list is a
    /// snapshot; the UI re-fetches when a picker opens or after a permission grant changes it.
    /// Returns `[]` when the platform can't enumerate (e.g. TCC not yet granted, or non-macOS).
    func availableInputDevices(_ kind: MediaDeviceKind) async -> [MediaInputDevice]

    /// Enable/disable the local microphone. The SDK owns capture + AEC. Needs
    /// `NSMicrophoneUsageDescription` + mic TCC. Toggling off unpublishes the audio track.
    func setMicrophone(enabled: Bool) async throws

    /// Route microphone capture to the input device with `deviceID` (an `id` from
    /// `availableInputDevices(.audioInput)`). No-op if the id isn't found. Takes effect for the
    /// current and subsequent mic capture.
    func selectAudioInput(deviceID: String) async

    /// Enable/disable the local webcam, capturing from the camera with `deviceID` (an `id` from
    /// `availableInputDevices(.videoInput)`; `nil` = system default). Publishes a camera video
    /// track when enabled, unpublishes when disabled. Needs `NSCameraUsageDescription` + camera TCC.
    func setCamera(enabled: Bool, deviceID: String?) async throws

    /// Whether the local participant currently has a published CAMERA video track (distinct from
    /// screen-share window tracks). Metadata only — does not open the capture device.
    func isCameraPublished() async -> Bool
}
