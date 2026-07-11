import SwiftUI
import Observation
import JoeScreenKit
import JoeScreenLiveKit
import JoeScreenCaptureMac
import ScreenCaptureKit
import AVFoundation
import LiveKit

/// The central @MainActor observable app state and orchestrator for the macOS client.
///
/// It owns the connection lifecycle (Direct Session Mode → LiveKit media plane), the roster, the
/// mirrored `RoomModel`, the remote video tracks (rendered as native NSWindows), and the local
/// capture/publish flow. This is where M2 (transport), M3 (capture), and M4 (the call UI + state
/// sync) come together into a working call.
@MainActor
@Observable
public final class AppModel {

    public enum Phase: Equatable {
        case idle
        case connecting
        case inCall
        case failed(String)
    }

    // MARK: - Observable state

    public private(set) var phase: Phase = .idle
    public private(set) var joinParameters: DirectJoinParameters?
    public private(set) var localParticipantID: ParticipantID?
    /// The mirrored room state. On the sharer this is the authoritative copy it broadcasts; on a
    /// joiner it's the last snapshot applied from the `state` channel (last-writer-wins on revision).
    public private(set) var room = RoomModel()
    public private(set) var participants: Set<ParticipantID> = []
    public private(set) var mediaState: MediaConnectionState = .disconnected
    public var showJoinSheet: Bool = true

    /// Remote video tracks we're rendering, keyed by JoeScreen windowID (parsed from the track name).
    /// The RemoteWindowManager opens/closes native NSWindows to match this set.
    public private(set) var remoteWindows: [WindowID: RemoteVideoWindow] = [:]

    // MARK: - Local media controls (mic + webcam)

    /// Whether the local microphone is currently publishing. Drives the mic toggle in the control bar.
    public private(set) var micEnabled: Bool = false
    /// Whether the local webcam is currently publishing. Drives the camera toggle in the control bar.
    public private(set) var cameraEnabled: Bool = false
    /// The selectable audio-input devices for the mic dropdown (refreshed on join / when opened).
    public private(set) var audioInputs: [MediaInputDevice] = []
    /// The selectable webcam devices for the camera dropdown (refreshed on join / after camera TCC).
    public private(set) var videoInputs: [MediaInputDevice] = []
    /// The chosen audio-input device id (nil = system default). Shows a checkmark in the mic dropdown.
    public private(set) var selectedAudioInputID: String?
    /// The chosen webcam device id (nil = system default). Shows a checkmark in the camera dropdown.
    public private(set) var selectedVideoInputID: String?
    /// The local webcam track for the self-preview tile; non-nil exactly while the camera is on.
    public private(set) var localCameraTrack: VideoTrack?

    /// The live connected-participant set as reported by the transport (local + all remotes). The
    /// authoritative membership source; the displayed `participants` roster is recomputed from this
    /// unioned with current share owners. Kept separate so disconnects actually remove people.
    private var transportParticipants: Set<ParticipantID> = []

    /// Windows this instance is locally sharing (capture services), keyed by windowID.
    private var localCaptures: [WindowID: WindowCaptureService] = [:]

    // MARK: - Collaborators

    private let transport = LiveKitTransport()
    private let windowManager = RemoteWindowManager()
    private var stateChannel: (any WireDataChannel)?
    private var cursorPump: CursorPump?

    private var launchJoin: DirectJoinParameters?
    private var launchJoinFired = false
    /// Optional CGWindowID to auto-share after joining (the --share-window-id automation path).
    private var autoShareWindowID: UInt32?
    private var pumps: [Task<Void, Never>] = []

    public init(launchJoin: DirectJoinParameters? = nil, autoShareWindowID: UInt32? = nil) {
        self.launchJoin = launchJoin
        self.autoShareWindowID = autoShareWindowID
        if launchJoin != nil { self.showJoinSheet = false }
        windowManager.model = self
    }

    // MARK: - Join entry points

    public func startLaunchJoinIfNeeded() {
        guard !launchJoinFired, let params = launchJoin else { return }
        launchJoinFired = true
        requestJoin(params)
    }

    public func requestJoin(_ params: DirectJoinParameters) {
        joinParameters = params
        localParticipantID = params.participantID
        showJoinSheet = false
        phase = .connecting
        Task { await connect(params) }
    }

    public func leave() {
        Task { await teardown() }
    }

    // MARK: - Connect

    private func connect(_ params: DirectJoinParameters) async {
        let identity = params.identity
        // Dev path: mint a local HS256 token (#if DEBUG). Production uses TokenClient (M7).
        #if DEBUG
        let token = DevTokenMinter.mint(identity: identity, room: params.room)
        #else
        let token: String
        do { token = try await TokenClient.fetch(server: params.serverURL, room: params.room, identity: identity) }
        catch { fail("token: \(error)"); return }
        #endif

        // Install the unified remote-track hook BEFORE connecting so we don't miss early
        // subscriptions. The descriptor carries the resolved ownerID (correct owner attribution at
        // subscribe time — no windowID fallback) and sourceKind (M10 camera routing).
        await transport.setOnRemoteTrack { [weak self] descriptor, track in
            guard let windowID = ShareTrackName.windowID(from: descriptor.trackName) else { return }
            let owner = descriptor.ownerID
            Task { @MainActor in self?.addRemoteWindow(windowID: windowID, ownerHint: owner, track: track) }
        }
        // Install the track-gone hook: a sharer that stops/crashes/disconnects fires this, and we
        // close + purge the corresponding viewer window (fixes the frozen-ghost leak).
        await transport.setOnTrackGone { [weak self] gone in
            guard let windowID = ShareTrackName.windowID(from: gone.trackName) else { return }
            Task { @MainActor in self?.handleRemoteTrackGone(windowID: windowID) }
        }

        // Install the participant-roster hook BEFORE connecting so early joiners aren't missed. This
        // is what makes EVERYONE connected appear in the roster — not just those who've shared a
        // window (the old snapshot-only derivation left non-sharing peers, and often yourself, absent).
        await transport.setOnParticipantsChanged { [weak self] ids in
            Task { @MainActor in self?.applyParticipantSet(ids) }
        }

        // Bridge connection state + participants.
        startConnectionPump()
        startParticipantPump()

        do {
            AppLog.info("connecting to \(params.serverURL.absoluteString) room=\(params.room) identity=\(identity)")
            try await transport.connect(.init(serverURL: params.serverURL, authToken: token))
            AppLog.info("connected; opening channels")
            try await transport.openAllDataChannels()
            let state = try await transport.openDataChannel(.state)
            self.stateChannel = state
            startStatePump(state)
            // Enable the mic on join (M5).
            try? await transport.setMicrophone(enabled: true)
            micEnabled = await transport.isMicrophoneEnabled()
            // Start the cursor pump (M6).
            let cursor = try await transport.openDataChannel(.cursor)
            let pump = CursorPump(channel: cursor, localID: localParticipantID)
            self.cursorPump = pump
            windowManager.cursorPump = pump
            startCursorInPump(pump)
            phase = .inCall
            // Seed the local participant into the roster immediately.
            if let me = localParticipantID { participants.insert(me) }
            // Pre-fill the input-device pickers OFF the join path: `CameraCapturer.captureDevices()`
            // can block / trigger the camera-TCC prompt, so it must never sit inline in connect (it
            // would stall the whole session — incl. remote-track rendering). The menus also refresh
            // on open, so an empty list here is harmless.
            Task { [weak self] in await self?.refreshInputDevices() }
            // Automation: auto-share a window if --share-window-id was passed.
            if let cgWindowID = autoShareWindowID {
                autoShareWindowID = nil
                shareWindow(cgWindowID: cgWindowID)
            }
        } catch {
            fail(String(describing: error))
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        showJoinSheet = false
    }

    private func teardown() async {
        for t in pumps { t.cancel() }
        pumps.removeAll()
        for (id, capture) in localCaptures {
            await capture.stop()
            await transport.unpublishVideoTrack(for: id)
        }
        localCaptures.removeAll()
        await transport.disconnect()
        windowManager.closeAll()
        remoteWindows.removeAll()
        micEnabled = false
        cameraEnabled = false
        localCameraTrack = nil
        audioInputs = []
        videoInputs = []
        selectedAudioInputID = nil
        selectedVideoInputID = nil
        phase = .idle
        participants = []
        transportParticipants = []
        room = RoomModel()
        localParticipantID = nil
        mediaState = .disconnected
        stateChannel = nil
        cursorPump = nil
        showJoinSheet = true
    }

    // MARK: - Pumps

    private func startConnectionPump() {
        let stream = transport.connectionStates()
        pumps.append(Task { @MainActor [weak self] in
            for await state in stream {
                self?.mediaState = state
                if case .failed(let r) = state { self?.fail(r) }
            }
        })
    }

    private func startParticipantPump() {
        // Roster is now driven by the transport's participant-changed hook (installed in `connect`),
        // which reports the full connected set (local + all remotes) on every connect/disconnect and
        // on (re)connect. `applyParticipantSet` merges it in. Share-owner derivation still runs too
        // (a joiner learns owners from state snapshots), so the two are unioned — never fight.
    }

    /// Record the authoritative connected-participant set from the transport and recompute the roster.
    /// This is the LIVE membership source (local + all connected remotes), so disconnects actually
    /// remove people — unlike the additive snapshot path.
    private func applyParticipantSet(_ ids: Set<ParticipantID>) {
        transportParticipants = ids
        recomputeRoster()
    }

    /// The displayed roster = live transport members ∪ current share owners ∪ me. Share owners are
    /// unioned in because a joiner can learn an owner from a state snapshot slightly before (or
    /// without) a bound media-plane identity; they drop off when their share vanishes + they're not a
    /// live transport member.
    private func recomputeRoster() {
        var roster = transportParticipants
        roster.formUnion(room.shares.values)
        if let me = localParticipantID { roster.insert(me) }
        participants = roster
    }

    private func startStatePump(_ channel: any WireDataChannel) {
        let incoming = channel.incoming()
        pumps.append(Task { @MainActor [weak self] in
            for await data in incoming {
                self?.applyStatePayload(data)
            }
        })
    }

    private func startCursorInPump(_ pump: CursorPump) {
        pumps.append(Task { @MainActor [weak self] in
            await pump.runInbound { windowID, participantID, point in
                self?.windowManager.updateRemoteCursor(windowID: windowID, participant: participantID, point: point)
            }
        })
    }

    /// Apply an inbound `state`-channel payload: a RoomSnapshot (full state, revision-gated) or a
    /// ShareEvent (open/close a viewer window promptly).
    private func applyStatePayload(_ data: Data) {
        guard let envelope = try? WireCodec.decode(data), let kind = envelope.kind else {
            return // unknown/unreadable — skip, never crash
        }
        switch kind {
        case .roomSnapshot:
            guard let snap = try? WireCodec.unpack(envelope, as: RoomSnapshot.self) else { return }
            // Last-writer-wins: only apply a strictly newer snapshot.
            if snap.model.revision > room.revision || room.revision == 0 {
                applyRoom(snap.model)
            }
        case .shareEvent:
            guard let ev = try? WireCodec.unpack(envelope, as: ShareEvent.self) else { return }
            if ev.action == .unshared { removeRemoteWindowIfForeign(ev.windowID) }
            // `shared` is handled when the track subscribes; the snapshot carries authoritative state.
        default:
            break
        }
    }

    /// Replace the mirrored room with `newRoom`, opening/closing viewer windows to match. Only a
    /// JOINER applies foreign snapshots; the local sharer's own windows are driven by its capture.
    private func applyRoom(_ newRoom: RoomModel) {
        room = newRoom
        // Recompute the roster (live transport members ∪ this snapshot's share owners ∪ me).
        recomputeRoster()
        // Close any remote viewer window whose share disappeared.
        for windowID in remoteWindows.keys where newRoom.owner(of: windowID) == nil {
            removeRemoteWindowIfForeign(windowID)
        }
    }

    // MARK: - Remote windows

    private func addRemoteWindow(windowID: WindowID, ownerHint: ParticipantID?,
                                 track: JoeScreenLiveKit.RemoteVideoTrackRef) {
        // A duplicate subscribe for a window we already show is a no-op — never open a second window.
        // (The reopen/replace-in-place path lands in M9.7 with the lifecycle reducer.)
        guard remoteWindows[windowID] == nil else { return }
        AppLog.info("remote track subscribed → opening native window for \(windowID)")
        // Owner attribution priority: authoritative snapshot > the descriptor's resolved identity >
        // the windowID (last-ditch, repaired later by applyRoom). The descriptor hint fixes the
        // subscribe-before-snapshot case that used to color/title the window wrong forever.
        let owner = room.owner(of: windowID) ?? ownerHint ?? windowID
        let win = RemoteVideoWindow(windowID: windowID, ownerID: owner, track: track)
        remoteWindows[windowID] = win
        // The track owner is definitely present; ensure they're in the roster even if the
        // participant-changed hook and this subscription race.
        transportParticipants.insert(owner)
        recomputeRoster()
        windowManager.open(win)
    }

    /// A remote sharer's track went away (stop/crash/disconnect). Close + purge its viewer window.
    private func handleRemoteTrackGone(windowID: WindowID) {
        guard remoteWindows[windowID] != nil else { return }
        AppLog.info("remote track gone → closing viewer window for \(windowID)")
        remoteWindows[windowID] = nil
        windowManager.close(windowID)
    }

    private func removeRemoteWindowIfForeign(_ windowID: WindowID) {
        guard remoteWindows[windowID] != nil else { return }
        remoteWindows[windowID] = nil
        windowManager.close(windowID)
    }

    // MARK: - Cursors (M6)

    /// Report the local user's pointer over a remote window; the pump coalesces + sends at ~60 fps.
    public func reportLocalCursor(windowID: WindowID, point: NormalizedPoint) {
        guard let pump = cursorPump else { return }
        let ts = ProcessInfo.processInfo.systemUptime
        Task { await pump.sendLocalCursor(windowID: windowID, point: point, timestamp: ts) }
    }

    // MARK: - Local media controls (mic + webcam)

    /// Re-fetch the AUDIO input list. Safe to call anytime — audio-device enumeration needs no TCC
    /// and doesn't touch the camera. Used to pre-fill the mic picker on join and when it opens.
    public func refreshAudioInputs() async {
        audioInputs = await transport.availableInputDevices(.audioInput)
    }

    /// Re-fetch the VIDEO (camera) input list. Kept OFF the join path and only called when the camera
    /// picker opens or after camera access is granted: `CameraCapturer.captureDevices()` runs an
    /// AVFoundation discovery session that can block, so enumerating it eagerly on join once stalled
    /// the whole session (incl. remote-track rendering). Enumeration itself doesn't prompt for TCC,
    /// but returns a limited/empty list until access is granted (toggleCamera preflights the grant).
    public func refreshVideoInputs() async {
        videoInputs = await transport.availableInputDevices(.videoInput)
    }

    /// Pre-fill both pickers. Audio is fetched inline; video is fetched in a detached task so a slow
    /// AVFoundation camera-discovery call can never block the caller (e.g. the join sequence).
    public func refreshInputDevices() async {
        await refreshAudioInputs()
        Task { [weak self] in await self?.refreshVideoInputs() }
    }

    /// Toggle the microphone on/off. LiveKit MUTES the mic publication on disable (it doesn't
    /// unpublish), so the live/muted state is read back from `isMicrophoneEnabled()` — not from
    /// publication existence, which would report "on" even while muted and wedge the toggle.
    public func toggleMic() {
        let target = !micEnabled
        // Optimistic UI: flip immediately so the icon responds even if the round-trip is slow, then
        // reconcile with the transport's real state.
        micEnabled = target
        Task {
            do {
                try await transport.setMicrophone(enabled: target)
            } catch {
                AppLog.error("toggleMic failed: \(String(describing: error))")
            }
            micEnabled = await transport.isMicrophoneEnabled()
        }
    }

    /// Route the mic to a specific input device (nil = keep current). Persists the selection so the
    /// checkmark and future captures follow it.
    public func selectAudioInput(_ deviceID: String) {
        selectedAudioInputID = deviceID
        Task { await transport.selectAudioInput(deviceID: deviceID) }
    }

    /// Toggle the webcam on/off. Enabling preflights camera TCC (deterministic system prompt) and,
    /// on success, publishes a camera track + exposes the local track for the self-preview tile.
    public func toggleCamera() {
        let target = !cameraEnabled
        Task {
            if target {
                let granted = await Self.ensureCameraAccess()
                guard granted else {
                    AppLog.error("camera access denied; not enabling webcam")
                    return
                }
                // A freshly granted permission makes new cameras enumerable — refresh that picker.
                await refreshVideoInputs()
            }
            do {
                try await transport.setCamera(enabled: target, deviceID: selectedVideoInputID)
            } catch {
                AppLog.error("toggleCamera failed: \(String(describing: error))")
            }
            cameraEnabled = await transport.isCameraPublished()
            localCameraTrack = cameraEnabled ? await transport.localCameraVideoTrack() : nil
        }
    }

    /// Switch the active webcam. If the camera is already on, republishes from the new device;
    /// otherwise just records the selection for the next enable.
    public func selectVideoInput(_ deviceID: String) {
        selectedVideoInputID = deviceID
        guard cameraEnabled else { return }
        Task {
            do {
                try await transport.setCamera(enabled: true, deviceID: deviceID)
                localCameraTrack = await transport.localCameraVideoTrack()
            } catch {
                AppLog.error("selectVideoInput failed: \(String(describing: error))")
            }
        }
    }

    /// Request camera TCC up front so the system prompt fires deterministically (mirrors the
    /// Screen-Recording preflight in `startSharing`). Returns whether access is authorized.
    private static func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Sharing

    /// Present the ScreenCaptureKit picker and share the chosen window (M3/M4).
    public func beginShare() {
        Task { await beginShareViaPicker() }
    }

    /// Share a specific OS window by CGWindowID (the picker callback AND the --share-window-id
    /// automation bypass both land here). The SCWindow is resolved inside the capture actor, so no
    /// non-Sendable object crosses an isolation boundary.
    public func shareWindow(cgWindowID: CGWindowID) {
        Task { await startSharing(cgWindowID: cgWindowID) }
    }

    private func beginShareViaPicker() async {
        // The picker (SCContentSharingPicker) calls back with the chosen window's CGWindowID.
        SharePicker.shared.present { [weak self] cgWindowID in
            Task { @MainActor in self?.shareWindow(cgWindowID: cgWindowID) }
        }
    }

    private func startSharing(cgWindowID: CGWindowID) async {
        guard let me = localParticipantID else { return }
        // Preflight Screen Recording so a missing grant triggers the system prompt deterministically
        // (rather than an opaque -3801 from SCStream). CGRequestScreenCaptureAccess shows the prompt
        // once; the user grants it, then rebuilds/relaunches (ad-hoc re-signing may re-prompt — R4).
        let hasAccess = CGPreflightScreenCaptureAccess()
        AppLog.info("startSharing cgWindowID=\(cgWindowID) screenCaptureAccess=\(hasAccess)")
        if !hasAccess {
            let granted = CGRequestScreenCaptureAccess()
            AppLog.info("requested screen capture access → \(granted)")
        }
        let windowID = WindowID()
        let capture = WindowCaptureService(windowID: windowID)
        localCaptures[windowID] = capture

        do {
            let sink = try await transport.publishVideoTrack(for: windowID)
            AppLog.info("publishVideoTrack sink ready for window \(windowID); starting capture")
            // Wire capture events → pause state + minimize-unshare.
            let events = await capture.events()
            pumps.append(Task { @MainActor [weak self] in
                for await event in events {
                    switch event {
                    case .paused: self?.setLocalPause(windowID, .paused)
                    case .resumed: self?.setLocalPause(windowID, .live)
                    case .minimizedShouldUnshare: self?.unshare(windowID)
                    case .stopped: self?.unshare(windowID)
                    case .frame: break
                    }
                }
            })
            try await capture.start(cgWindowID: cgWindowID, sink: sink)
            AppLog.info("capture started for cgWindowID=\(cgWindowID); broadcasting share")
            // Update authoritative room + broadcast.
            room.addShare(windowID, owner: me)
            await transport.updateShareContext(windowCount: localCaptures.count, wholeDisplay: false)
            broadcastState()
            broadcastShareEvent(.shared, windowID: windowID, owner: me)
        } catch {
            AppLog.error("startSharing failed: \(String(describing: error))")
            localCaptures[windowID] = nil
            await transport.unpublishVideoTrack(for: windowID)
        }
    }

    public func unshare(_ windowID: WindowID) {
        Task { await unshareAsync(windowID) }
    }

    private func unshareAsync(_ windowID: WindowID) async {
        guard let me = localParticipantID, room.owner(of: windowID) == me else { return }
        if let capture = localCaptures[windowID] { await capture.stop() }
        localCaptures[windowID] = nil
        await transport.unpublishVideoTrack(for: windowID)
        room.removeShare(windowID)
        broadcastState()
        broadcastShareEvent(.unshared, windowID: windowID, owner: me)
    }

    private func setLocalPause(_ windowID: WindowID, _ state: RoomModel.PauseState) {
        guard room.owner(of: windowID) == localParticipantID else { return }
        if room.setPauseState(state, window: windowID) { broadcastState() }
    }

    // MARK: - State broadcast

    private func broadcastState() {
        guard let me = localParticipantID, let channel = stateChannel else { return }
        let snap = RoomSnapshot(model: room)
        guard let env = try? WireCodec.pack(snap, sender: me),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    private func broadcastShareEvent(_ action: ShareEvent.Action, windowID: WindowID, owner: ParticipantID) {
        guard let channel = stateChannel else { return }
        let ev = ShareEvent(action: action, windowID: windowID, ownerID: owner, revision: room.revision)
        guard let env = try? WireCodec.pack(ev, sender: owner),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    // MARK: - Roster helpers

    public var sharedWindowsSorted: [SharedWindowEntry] {
        room.shares
            .map { SharedWindowEntry(window: $0.key, owner: $0.value) }
            .sorted { $0.window.uuidString < $1.window.uuidString }
    }

    public struct SharedWindowEntry: Equatable {
        public let window: WindowID
        public let owner: ParticipantID
    }

    public func color(for id: ParticipantID) -> Color {
        let c = ParticipantColor.components(for: id)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    public func shortLabel(for id: ParticipantID) -> String {
        String(id.uuidString.prefix(4))
    }
}
