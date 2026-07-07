import Foundation
import LiveKit
import JoeScreenKit

/// The concrete `MediaTransport` (JoeScreenKit seam) over LiveKit — the ONLY libwebrtc-linking type
/// in the process (D3/D7/R22). An actor so all mutable state (room, channels, identity map, track
/// registry) is serialized; the `@objc` room delegate hops onto it from LiveKit's callback threads.
///
/// Responsibilities (§2/§3):
///   • Room lifecycle: connect with adaptiveStream+dynacast BOTH true (R24 selective subscription),
///     disconnect, and bridge the delegate's connection-state stream.
///   • Video: one buffer track per shared window, named `window:<uuid>` so receivers map track→window;
///     the frame-before-publish handshake (≥1 frame captured before `publish`) is honored via the sink.
///   • Data: six topic-mapped channels (iterate `DataChannel.allCases`), reliability from ChannelPolicy,
///     Chunker for >14 KB reliable payloads.
///   • Identity: bind a ParticipantID to a transport identity string; parse remote identities back.
/// A remote video track reference the app layer can hand to `SwiftUIVideoView(track)` for rendering,
/// without the app naming LiveKit's `RemoteVideoTrack` type directly everywhere. It IS the LiveKit
/// track (the app target links LiveKit); this alias documents the boundary.
public typealias RemoteVideoTrackRef = RemoteVideoTrack

public actor LiveKitTransport: MediaTransport {

    // MARK: - State

    private let room: Room
    private var observer: LiveKitRoomObserver?

    /// Cached data channels by DataChannel (openDataChannel returns the same instance).
    private var dataChannels: [DataChannel: LiveKitDataChannel] = [:]

    /// Published video tracks + their sinks, keyed by windowID. `publication` is nil between sink
    /// creation and the publish returning (the frame-before-publish window).
    private struct PublishedTrack {
        let track: LocalVideoTrack
        let sink: LiveKitVideoFrameSink
        var publication: LocalTrackPublication?
    }
    private var publishedTracks: [WindowID: PublishedTrack] = [:]

    /// Identity binding: transport identity string ↔ ParticipantID (§3 input-authorization needs it).
    private var identityToParticipant: [String: ParticipantID] = [:]
    private var participantToIdentity: [ParticipantID: String] = [:]

    /// Connection-state fan-out. Lives in a thread-safe broadcaster (not actor-isolated) so the
    /// SYNCHRONOUS `connectionStates()` protocol requirement can be satisfied `nonisolated`.
    private let stateBroadcaster = ConnectionStateBroadcaster()

    /// Remote video tracks by track name (for receiver-side rendering hooks, M2 test + M4 UI).
    private var remoteVideoTracks: [String: RemoteVideoTrack] = [:]
    /// Optional renderer factory: given a track name + track, produce/attach a renderer. Set by the
    /// app (M4) or a test (M2) to observe received frames. Nil = no rendering side effects.
    private var onTrackSubscribed: (@Sendable (String, RemoteVideoTrack) -> Void)?

    /// Codec selection feeding VideoPublishOptions (D5). One selector describes the current share
    /// context; the app updates window count on share/unshare.
    private var codecSelector = CodecSelector(windowCount: 1)

    // MARK: - Init

    /// - Parameter room: injectable for tests (two Rooms in one process). Defaults to a fresh Room.
    public init(room: Room = Room()) {
        self.room = room
    }

    /// Install a hook invoked whenever a remote video track is subscribed (M2 test observes frames;
    /// M4 app attaches a SwiftUIVideoView / renderer). Idempotent; last writer wins.
    public func setOnTrackSubscribed(_ handler: @escaping @Sendable (String, RemoteVideoTrack) -> Void) {
        self.onTrackSubscribed = handler
        // Fire for any already-subscribed tracks so a late observer doesn't miss them.
        for (name, track) in remoteVideoTracks { handler(name, track) }
    }

    /// The underlying room (for app-layer rendering that needs SwiftUIVideoView(track)).
    public var underlyingRoom: Room { room }

    // MARK: - MediaTransport

    public func connect(_ configuration: MediaTransportConfiguration) async throws {
        let observer = LiveKitRoomObserver(transport: self)
        self.observer = observer
        room.add(delegate: observer)

        // R24: selective subscription is load-bearing correctness, not optimization — set BOTH true.
        let roomOptions = RoomOptions(adaptiveStream: true, dynacast: true)

        updateState(.connecting)
        do {
            try await room.connect(
                url: configuration.serverURL.absoluteString,
                token: configuration.authToken,
                connectOptions: nil,
                roomOptions: roomOptions)
        } catch {
            updateState(.failed(reason: String(describing: error)))
            throw error
        }
        // Bind the local participant's identity too (its JWT sub), so self-attribution works.
        if let localIdentity = room.localParticipant.identity?.stringValue,
           let pid = ParticipantID(uuidString: localIdentity) {
            identityToParticipant[localIdentity] = pid
            participantToIdentity[pid] = localIdentity
        }
        updateState(.connected)
    }

    public func disconnect() async {
        await room.disconnect()
        for ch in dataChannels.values { ch.finish() }
        dataChannels.removeAll()
        publishedTracks.removeAll()
        remoteVideoTracks.removeAll()
        if let observer { room.remove(delegate: observer) }
        observer = nil
        updateState(.disconnected)
        // Keep the broadcaster alive (callers may reconnect); only finish it on deinit-equivalent.
    }

    public nonisolated func connectionStates() -> AsyncStream<MediaConnectionState> {
        stateBroadcaster.stream()
    }

    public func bindIdentity(_ participantID: ParticipantID, transportIdentity: String) async {
        identityToParticipant[transportIdentity] = participantID
        participantToIdentity[participantID] = transportIdentity
    }

    /// Map a transport identity string back to a ParticipantID. Prefers an explicit binding; falls
    /// back to parsing the identity as a UUID (our tokens set sub = ParticipantID.uuidString). Returns
    /// nil for unparseable identities (the transport rejects them — §3).
    public func participantID(forIdentity identity: String) -> ParticipantID? {
        identityToParticipant[identity] ?? UUID(uuidString: identity)
    }

    public func publishVideoTrack(for windowID: WindowID) async throws -> any VideoFrameSink {
        if let existing = publishedTracks[windowID] { return existing.sink }

        // Track name encodes the window so receivers map track → window (§3).
        let trackName = LiveKitTransport.trackName(for: windowID)
        let track = LocalVideoTrack.createBufferTrack(
            name: trackName,
            source: .screenShareVideo,
            options: BufferCaptureOptions())
        guard let capturer = track.capturer as? BufferCapturer else {
            throw TransportError.capturerUnavailable
        }
        let sink = LiveKitVideoFrameSink(track: track, capturer: capturer)

        // Register the sink immediately (publication nil for now) so the caller can start feeding
        // frames and a re-entrant publish returns the same sink instead of a second track.
        publishedTracks[windowID] = PublishedTrack(track: track, sink: sink, publication: nil)

        // Frame-before-publish handshake (§3): the actual `publish` must run AFTER ≥1 frame is
        // captured or it times out. We return the sink NOW (so the caller — capture engine or test —
        // starts feeding it) and publish in a detached task the instant the first frame lands. This
        // is the real capture-pipeline shape: get the sink, feed it, the track goes live on frame 1.
        let publishOptions = makeVideoPublishOptions()
        Task { [weak self] in
            await sink.waitForFirstFrame()
            guard let self else { return }
            await self.completePublish(windowID: windowID, track: track, options: publishOptions)
        }
        return sink
    }

    /// Finish publishing a track once its first frame has been captured (frame-before-publish).
    private func completePublish(windowID: WindowID, track: LocalVideoTrack, options: VideoPublishOptions) async {
        // The share may have been unpublished during the wait; bail if so.
        guard publishedTracks[windowID]?.track === track else { return }
        do {
            let publication = try await room.localParticipant.publish(videoTrack: track, options: options)
            publishedTracks[windowID]?.publication = publication
        } catch {
            // Publish failed (e.g. disconnected mid-handshake). Surface as a state blip; the caller's
            // higher-level share flow can retry. We don't crash a live session over one track.
            updateState(.failed(reason: "publish failed: \(String(describing: error))"))
        }
    }

    public func unpublishVideoTrack(for windowID: WindowID) async {
        guard let entry = publishedTracks[windowID] else { return }
        publishedTracks[windowID] = nil
        if let publication = entry.publication {
            try? await room.localParticipant.unpublish(publication: publication)
        }
    }

    public func openDataChannel(_ channel: DataChannel) async throws -> any WireDataChannel {
        if let existing = dataChannels[channel] { return existing }
        let ch = LiveKitDataChannel(channel: channel, room: room)
        dataChannels[channel] = ch
        return ch
    }

    /// Open ALL six channels eagerly (iterate allCases — do not hardcode five). The app/test calls
    /// this once after connect so inbound demux has a home for every topic.
    public func openAllDataChannels() async throws {
        for channel in DataChannel.allCases {
            _ = try await openDataChannel(channel)
        }
    }

    // MARK: - Voice (M5)

    /// Enable/disable the local microphone. LiveKit owns capture + AEC (supersedes D13's hand-rolled
    /// pipeline for the LiveKit path — recorded in DECISIONS D13-A / M5).
    public func setMicrophone(enabled: Bool) async throws {
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    /// Whether the local participant currently has a published microphone track (M5 test hook).
    public func isMicrophonePublished() -> Bool {
        room.localParticipant.trackPublications.values.contains {
            $0.source == .microphone && $0.track != nil
        }
    }

    // MARK: - Codec context (D5)

    /// Update the share context so VideoPublishOptions reflect single-window VP9 vs multi-window H.264.
    public func updateShareContext(windowCount: Int, wholeDisplay: Bool) {
        codecSelector = CodecSelector(windowCount: windowCount, wholeDisplay: wholeDisplay)
    }

    private func makeVideoPublishOptions() -> VideoPublishOptions {
        // VP9 IS requestable (§3); contentHint is unreachable at 2.15.1 (R31) — source:.screenShareVideo
        // on the track is the closest lever, already set at track creation.
        let preferred: LiveKit.VideoCodec = codecSelector.current == .vp9 ? .vp9 : .h264
        return VideoPublishOptions(
            name: nil,
            encoding: nil,
            screenShareEncoding: nil,
            simulcast: false,                       // single window: no simulcast (D5)
            simulcastLayers: [],
            screenShareSimulcastLayers: [],
            preferredCodec: preferred,
            preferredBackupCodec: nil,
            degradationPreference: .maintainResolution, // legibility invariant (D5)
            streamName: nil)
    }

    // MARK: - Handlers (called by the observer, serialized on the actor)

    func handleConnectionState(_ state: MediaConnectionState) {
        updateState(state)
    }

    func handleParticipantConnected(identity: String?) {
        guard let identity, let pid = participantID(forIdentity: identity) else { return }
        identityToParticipant[identity] = pid
        participantToIdentity[pid] = identity
    }

    func handleParticipantDisconnected(identity: String?) {
        guard let identity else { return }
        if let pid = identityToParticipant[identity] {
            participantToIdentity[pid] = nil
        }
        identityToParticipant[identity] = nil
    }

    func handleTrackSubscribed(identity: String?, trackName: String, videoTrack: RemoteVideoTrack?) {
        guard let videoTrack else { return }
        remoteVideoTracks[trackName] = videoTrack
        onTrackSubscribed?(trackName, videoTrack)
    }

    func handleTrackUnsubscribed(trackName: String) {
        remoteVideoTracks[trackName] = nil
    }

    func handleData(_ data: Data, topic: String) {
        guard let channel = DataChannel(rawValue: topic), let ch = dataChannels[channel] else {
            return // unknown topic (or channel not opened) — skip, never crash
        }
        ch.receive(data)
    }

    // MARK: - Internals

    private func updateState(_ state: MediaConnectionState) {
        stateBroadcaster.emit(state)
    }

    /// Track naming convention: `window:<windowID uuid>` (§3). Receivers parse the window back out.
    public static func trackName(for windowID: WindowID) -> String {
        "window:\(windowID.uuidString)"
    }

    /// Parse a window ID out of a track name produced by `trackName(for:)`; nil if it isn't one.
    public static func windowID(fromTrackName name: String) -> WindowID? {
        guard name.hasPrefix("window:") else { return nil }
        return UUID(uuidString: String(name.dropFirst("window:".count)))
    }

    public enum TransportError: Error, Equatable {
        case capturerUnavailable
    }
}
