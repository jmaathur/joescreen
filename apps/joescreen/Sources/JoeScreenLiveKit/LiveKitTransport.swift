import Foundation
import AVFoundation
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

    /// The local webcam publication (the "camera bubble" — distinct from screen-share window
    /// tracks). Nil when the camera is off. LiveKit owns the camera capturer; we keep the
    /// publication only to unpublish and to reach the local track for self-preview.
    private var cameraPublication: LocalTrackPublication?

    /// Identity binding: transport identity string ↔ ParticipantID (§3 input-authorization needs it).
    private var identityToParticipant: [String: ParticipantID] = [:]
    private var participantToIdentity: [ParticipantID: String] = [:]

    /// Connection-state fan-out. Lives in a thread-safe broadcaster (not actor-isolated) so the
    /// SYNCHRONOUS `connectionStates()` protocol requirement can be satisfied `nonisolated`.
    private let stateBroadcaster = ConnectionStateBroadcaster()

    /// One subscribed remote video track + its descriptor, keyed by the stable track **SID** (NOT
    /// name — LiveKit names every camera track `"camera"`, so a name key would overwrite one webcam
    /// with another; latent bug #1). The descriptor carries name/sourceKind/ownerID for routing.
    private struct SubscribedTrack {
        let track: RemoteVideoTrack
        let descriptor: RemoteTrackDescriptor
        /// Per-track dimension observer, retained here (the SDK holds delegates weakly).
        var dimensionObserver: TrackDimensionObserver?
    }
    private var remoteVideoTracks: [String: SubscribedTrack] = [:]

    /// The unified remote-track hook (the design panel's superset contract): given a descriptor +
    /// the LiveKit track, route/render it. Set by the app (M4/M9/M10) or a test (M2). Nil = no side
    /// effects. Idempotent; last writer wins; fires once per already-subscribed track on install.
    private var onRemoteTrack: (@Sendable (RemoteTrackDescriptor, RemoteVideoTrack) -> Void)?

    /// The unified track-gone hook, fired from BOTH unsubscribe AND unpublish (deduped). The app
    /// closes/purges the corresponding viewer window (fixes the frozen-ghost leak).
    private var onTrackGone: (@Sendable (RemoteTrackGone) -> Void)?

    /// Optional hook fired with a subscribed track's pixel dimensions (seeded at subscribe, then on
    /// each `didUpdateDimensions`). The app uses it to keep a viewer window aspect-true. (width, height.)
    private var onTrackDimensions: (@Sendable (RemoteTrackDescriptor, Int, Int) -> Void)?

    /// SIDs we've already reported gone this session, so the unsubscribe→unpublish pair fires once.
    private var reportedGone: Set<String> = []
    /// SIDs we unsubscribed OURSELVES (a user-close / soft-hide), so the resulting delegate callback
    /// is suppressed — that's a self-inflicted event, not a sharer disappearing.
    private var locallyUnsubscribed: Set<String> = []

    /// windowID → the SID of its currently-subscribed share track, so `setWindowTrackSubscribed`
    /// and dimension updates can find the publication by window without re-deriving from names.
    private var windowTrackSIDs: [WindowID: String] = [:]

    /// Optional hook fired whenever the participant set changes (someone connects/disconnects, or a
    /// (re)connection re-seeds the roster). Carries the CURRENT full set of participant IDs (remote +
    /// local). The app drives its roster from this so peers appear even before they share anything.
    private var onParticipantsChanged: (@Sendable (Set<ParticipantID>) -> Void)?

    /// Codec selection feeding VideoPublishOptions (D5). One selector describes the current share
    /// context; the app updates window count on share/unshare.
    private var codecSelector = CodecSelector(windowCount: 1)

    // MARK: - Init

    /// - Parameter room: injectable for tests (two Rooms in one process). Defaults to a fresh Room.
    public init(room: Room = Room()) {
        self.room = room
    }

    /// Install the unified remote-track hook (descriptor + track). Idempotent; last writer wins.
    /// Fires once for every already-subscribed track so a late observer isn't missed.
    public func setOnRemoteTrack(_ handler: @escaping @Sendable (RemoteTrackDescriptor, RemoteVideoTrack) -> Void) {
        self.onRemoteTrack = handler
        for entry in remoteVideoTracks.values { handler(entry.descriptor, entry.track) }
    }

    /// Install the unified track-gone hook (fired from unsubscribe + unpublish, deduped).
    public func setOnTrackGone(_ handler: @escaping @Sendable (RemoteTrackGone) -> Void) {
        self.onTrackGone = handler
    }

    /// Install the dimensions hook (width, height pixels, per subscribed track).
    public func setOnTrackDimensions(_ handler: @escaping @Sendable (RemoteTrackDescriptor, Int, Int) -> Void) {
        self.onTrackDimensions = handler
    }

    /// Hard subscribe/unsubscribe a window's share track at the SFU (`set(subscribed:)`) — zero
    /// downlink when off. Used for user-close (off) and reopen (on). NEVER `set(enabled:)` (throws
    /// under adaptiveStream — R24). Marks the SID `locallyUnsubscribed` BEFORE the call so the
    /// resulting delegate callback is recognized as self-inflicted, not a sharer disappearing.
    public func setWindowTrackSubscribed(windowID: WindowID, _ subscribed: Bool) async {
        guard let sid = windowTrackSIDs[windowID],
              let publication = remoteTrackPublication(forSID: sid) else { return }
        if !subscribed { locallyUnsubscribed.insert(sid) } else { locallyUnsubscribed.remove(sid) }
        // A failed toggle is non-fatal: adaptiveStream + renderer detach already govern downlink, and
        // the lifecycle reducer drives the visible state. If it threw, undo the self-suppress mark so
        // a genuine later gone still fires.
        do { try await publication.set(subscribed: subscribed) }
        catch { if !subscribed { locallyUnsubscribed.remove(sid) } }
    }

    /// Find the remote publication for a SID by scanning the room's remote participants. Publications
    /// aren't indexed by SID publicly, so this linear scan (few participants × few tracks) is fine.
    private func remoteTrackPublication(forSID sid: String) -> RemoteTrackPublication? {
        for participant in room.remoteParticipants.values {
            for pub in participant.trackPublications.values {
                if pub.sid.stringValue == sid, let remote = pub as? RemoteTrackPublication {
                    return remote
                }
            }
        }
        return nil
    }

    /// Install a hook fired whenever the participant set changes. Fires ONCE immediately with the
    /// current set so a late observer is seeded, then on every connect/disconnect. Idempotent.
    public func setOnParticipantsChanged(_ handler: @escaping @Sendable (Set<ParticipantID>) -> Void) {
        self.onParticipantsChanged = handler
        handler(currentParticipantIDs())
    }

    /// The current full participant set: the local participant plus every connected remote. Derived
    /// live from the room, so it's correct after (re)connects regardless of who has shared anything.
    public func currentParticipantIDs() -> Set<ParticipantID> {
        var ids = Set<ParticipantID>()
        if let localIdentity = room.localParticipant.identity?.stringValue,
           let pid = participantID(forIdentity: localIdentity) {
            ids.insert(pid)
        }
        for participant in room.remoteParticipants.values {
            if let identity = participant.identity?.stringValue,
               let pid = participantID(forIdentity: identity) {
                ids.insert(pid)
            }
        }
        return ids
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
        cameraPublication = nil
        remoteVideoTracks.removeAll()
        reportedGone.removeAll()
        locallyUnsubscribed.removeAll()
        windowTrackSIDs.removeAll()
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
    /// AVAudioEngine+Opus pipeline for the LiveKit path — DECISIONS D13-A / M5). This opens the real
    /// mic device and needs `NSMicrophoneUsageDescription` + mic TCC.
    public func setMicrophone(enabled: Bool) async throws {
        _ = try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    /// Whether the local participant currently has a published audio track (M5 test hook — checks
    /// publication metadata WITHOUT opening the capture device). NOTE: `setMicrophone(enabled:false)`
    /// MUTES the track rather than unpublishing it, so this stays true while muted — use
    /// `isMicrophoneEnabled()` for the on/off UI state, and this only to assert a track exists.
    public func isAudioPublished() -> Bool {
        room.localParticipant.audioTracks.contains { $0.track != nil }
    }

    /// Whether the mic is currently LIVE (published AND unmuted). This is the correct source of truth
    /// for the mute toggle: LiveKit mutes the mic publication on disable rather than unpublishing it,
    /// so publication-existence alone would report "on" even while muted.
    public func isMicrophoneEnabled() -> Bool {
        room.localParticipant.isMicrophoneEnabled()
    }

    /// Count of remote audio-track publications this participant currently sees (M5 cross-Room
    /// subscription assertion — metadata only, no device access).
    public func remoteAudioTrackCount() -> Int {
        var count = 0
        for participant in room.remoteParticipants.values {
            count += participant.audioTracks.count
        }
        return count
    }

    // MARK: - Local capture devices (mic input + webcam) — F11 camera bubbles

    /// Enumerate selectable input devices of `kind`. Cameras come from `CameraCapturer.captureDevices()`
    /// (AVFoundation, gated by camera TCC); audio inputs from LiveKit's macOS `AudioManager`. Returns
    /// `[]` if enumeration throws (e.g. TCC not yet granted) rather than surfacing an error to the UI.
    public func availableInputDevices(_ kind: MediaDeviceKind) async -> [MediaInputDevice] {
        switch kind {
        case .videoInput:
            guard let devices = try? await CameraCapturer.captureDevices() else { return [] }
            // AVFoundation has no "is default camera" concept; leave isDefault false for all.
            return devices.map { MediaInputDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: false) }
        case .audioInput:
            return AudioManager.shared.inputDevices.map {
                MediaInputDevice(id: $0.deviceId, name: $0.name, isDefault: $0.isDefault)
            }
        }
    }

    /// Route mic capture to the input device with `deviceID`. macOS-only (AudioManager input-device
    /// selection is a no-op elsewhere); an unknown id is ignored.
    public func selectAudioInput(deviceID: String) async {
        guard let device = AudioManager.shared.inputDevices.first(where: { $0.deviceId == deviceID }) else { return }
        AudioManager.shared.inputDevice = device
    }

    /// Enable/disable the local webcam, capturing from `deviceID` (nil = system default). Publishes a
    /// `.camera`-source video track when enabled; unpublishes when disabled. LiveKit owns the camera
    /// capturer + encode. Needs `NSCameraUsageDescription` + camera TCC (the app preflights the grant).
    public func setCamera(enabled: Bool, deviceID: String?) async throws {
        guard enabled else {
            _ = try await room.localParticipant.setCamera(enabled: false)
            cameraPublication = nil
            return
        }
        // Resolve the chosen AVCaptureDevice so the capture options bind to that exact camera.
        var captureOptions: CameraCaptureOptions?
        if let deviceID {
            let devices = try await CameraCapturer.captureDevices()
            if let device = devices.first(where: { $0.uniqueID == deviceID }) {
                captureOptions = CameraCaptureOptions(device: device)
            }
        }
        cameraPublication = try await room.localParticipant.setCamera(
            enabled: true, captureOptions: captureOptions)
    }

    /// The local webcam video track for a self-preview (`SwiftUIVideoView(track, mirrorMode: .mirror)`).
    /// Nil when the camera is off. LiveKit-typed on purpose — this is an app-layer rendering
    /// convenience on the concrete adapter, NOT part of the framework-free `MediaTransport` seam.
    public func localCameraVideoTrack() -> VideoTrack? {
        room.localParticipant.firstCameraVideoTrack
    }

    /// Whether the camera is currently LIVE (published AND unmuted). Correct source of truth for the
    /// camera toggle: like the mic, `setCamera(enabled:false)` mutes rather than unpublishes, so
    /// publication-existence alone would report "on" while the camera is muted.
    public func isCameraPublished() -> Bool {
        room.localParticipant.isCameraEnabled()
    }

    /// Count of remote CAMERA video-track publications this participant sees (cross-Room assertion —
    /// metadata only). Excludes screen-share window tracks.
    public func remoteVideoTrackCount() -> Int {
        var count = 0
        for participant in room.remoteParticipants.values {
            count += participant.videoTracks.filter { $0.source == .camera }.count
        }
        return count
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
        // On (re)connect the room re-seeds its participant list; refresh the roster so peers that
        // were present across a reconnect reappear.
        if state == .connected { onParticipantsChanged?(currentParticipantIDs()) }
    }

    func handleParticipantConnected(identity: String?) {
        if let identity, let pid = participantID(forIdentity: identity) {
            identityToParticipant[identity] = pid
            participantToIdentity[pid] = identity
        }
        onParticipantsChanged?(currentParticipantIDs())
    }

    func handleParticipantDisconnected(identity: String?) {
        if let identity {
            if let pid = identityToParticipant[identity] {
                participantToIdentity[pid] = nil
            }
            identityToParticipant[identity] = nil
        }
        onParticipantsChanged?(currentParticipantIDs())
    }

    func handleTrackSubscribed(
        identity: String?,
        trackSID: String,
        trackName: String,
        sourceKind: RemoteTrackSourceKind,
        seedDimensions: Dimensions?,
        videoTrack: RemoteVideoTrack?
    ) {
        guard let videoTrack else { return }
        let ownerID = identity.flatMap { participantID(forIdentity: $0) }
        let descriptor = RemoteTrackDescriptor(
            trackSID: trackSID, trackName: trackName, sourceKind: sourceKind, ownerID: ownerID)

        // A re-subscribe of the same SID clears any stale gone/local-unsubscribe marks.
        reportedGone.remove(trackSID)
        locallyUnsubscribed.remove(trackSID)

        // Attach a per-track dimension observer (weak in the SDK — we retain it). Seed the current
        // dimensions so the app can aspect-size the window before the first didUpdateDimensions.
        let observer = TrackDimensionObserver(trackSID: trackSID) { [weak self] sid, dims in
            Task { [weak self] in await self?.handleTrackDimensions(trackSID: sid, dimensions: dims) }
        }
        videoTrack.add(delegate: observer)

        remoteVideoTracks[trackSID] = SubscribedTrack(
            track: videoTrack, descriptor: descriptor, dimensionObserver: observer)
        if let windowID = ShareTrackName.windowID(from: trackName) {
            windowTrackSIDs[windowID] = trackSID
        }

        onRemoteTrack?(descriptor, videoTrack)
        // Deliver the seed dimensions immediately if the SDK already knows them at subscribe.
        if let seedDimensions {
            handleTrackDimensions(trackSID: trackSID, dimensions: seedDimensions)
        }
    }

    /// Delegate callback source: the SDK's unsubscribe. May be self-inflicted (a local hard
    /// unsubscribe for user-close) — suppressed via `locallyUnsubscribed`.
    func handleTrackUnsubscribed(trackSID: String) {
        reportGone(trackSID: trackSID, viaUnpublish: false)
    }

    /// Delegate callback source: the SDK's unpublish (the remote sharer stopped/crashed). This is
    /// ALWAYS authoritative — we never unpublish a REMOTE track, so it is never self-inflicted. It
    /// therefore reports gone even if the SID was locally unsubscribed (the sharer really left while
    /// its viewer was closed — otherwise that entry would leak forever). Hooking unsubscribe alone
    /// would miss this: a locally-unsubscribed track fires ONLY unpublish on a later crash (verified).
    func handleTrackUnpublished(trackSID: String) {
        reportGone(trackSID: trackSID, viaUnpublish: true)
    }

    /// Dimension updates for a subscribed track (seeded at subscribe, then on didUpdateDimensions).
    /// Currently surfaced via the descriptor's ownerID/name so the app can re-aspect the window; the
    /// dimensions themselves reach the app through the ShareInfo re-broadcast on the sharer side and
    /// the renderer's own layout, so this hook exists for future explicit dimension push (M9 app).
    func handleTrackDimensions(trackSID: String, dimensions: Dimensions?) {
        guard remoteVideoTracks[trackSID] != nil, let dimensions,
              let handler = onTrackDimensions else { return }
        let entry = remoteVideoTracks[trackSID]!
        handler(entry.descriptor, Int(dimensions.width), Int(dimensions.height))
    }

    /// Fire the gone hook exactly once per SID, suppressing self-inflicted unsubscribes but never a
    /// real unpublish.
    private func reportGone(trackSID: String, viaUnpublish: Bool) {
        // A local hard unsubscribe (user-close) produces a self-inflicted UNSUBSCRIBE callback — swallow
        // it (not "the sharer disappeared"). An UNPUBLISH is never self-inflicted for a remote track,
        // so it always reports: the sharer genuinely left, even while its viewer was locally closed —
        // otherwise the entry would leak forever (the closed-by-user Reopen tile would be stuck).
        if !viaUnpublish && locallyUnsubscribed.contains(trackSID) {
            return
        }
        // A confirmed unpublish clears the self-suppress mark so bookkeeping stays consistent.
        locallyUnsubscribed.remove(trackSID)
        guard !reportedGone.contains(trackSID) else { return }
        reportedGone.insert(trackSID)
        guard let entry = remoteVideoTracks[trackSID] else {
            // Never saw the subscribe (or already purged). Nothing to report against.
            return
        }
        let gone = RemoteTrackGone(
            trackSID: trackSID,
            trackName: entry.descriptor.trackName,
            sourceKind: entry.descriptor.sourceKind,
            ownerID: entry.descriptor.ownerID)
        remoteVideoTracks[trackSID] = nil
        if let windowID = ShareTrackName.windowID(from: gone.trackName),
           windowTrackSIDs[windowID] == trackSID {
            windowTrackSIDs[windowID] = nil
        }
        onTrackGone?(gone)
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

    /// Track naming convention: `window:<windowID uuid>` (§3). Delegates to the single `ShareTrackName`
    /// contract so window-share naming has exactly one implementation (byte-identical output).
    public static func trackName(for windowID: WindowID) -> String {
        ShareTrackName.encode(kind: .window, windowID: windowID)
    }

    /// Parse a window ID out of a WINDOW-share track name; nil for camera/display/garbage. Retained
    /// for the existing window-only call sites (iOS viewer); delegates to `ShareTrackName`.
    public static func windowID(fromTrackName name: String) -> WindowID? {
        guard let parsed = ShareTrackName.decode(name), parsed.kind == .window else { return nil }
        return parsed.windowID
    }

    public enum TransportError: Error, Equatable {
        case capturerUnavailable
    }
}
