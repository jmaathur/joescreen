import SwiftUI
import Observation
import JoeScreenKit
import JoeScreenLiveKit
import JoeScreenCaptureMac
import JoeScreenInputMac
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

    /// Per-participant live media presence (name/speaking/mic/camera) for the tile strip (M10),
    /// pushed reactively from the transport. cameraOn distinguishes "show video" from "show avatar"
    /// (a muted camera stays subscribed → cameraTracks still holds it, but cameraOn is false).
    public private(set) var participantMedia: [ParticipantID: ParticipantMediaState] = [:]

    /// Remote participant CAMERA tracks (M10), keyed by owner. Distinct from window shares — these
    /// render as tiles in the participant strip, not native windows. A muted camera stays subscribed
    /// (LiveKit mutes rather than unpublishes), so presence here means "renderable camera track"; the
    /// cameraOn flag in ParticipantMediaState governs whether to show video vs an avatar.
    public private(set) var cameraTracks: [ParticipantID: JoeScreenLiveKit.RemoteVideoTrackRef] = [:]
    /// The SID that delivered each owner's camera track, so a trackGone for that SID clears it.
    private var cameraTrackSIDs: [ParticipantID: String] = [:]

    /// Per-window lifecycle state machines (M9). AppModel feeds events (subscribe/gone/close/
    /// reopen/miniaturize/occlude/reconnecting/snapshot-removal) and EXECUTES the returned effects.
    /// All the dead-window/desync correctness lives in the pure `RemoteWindowLifecycle` reducer.
    private var lifecycles: [WindowID: RemoteWindowLifecycle] = [:]
    /// Grace timers for windows parked in `.stale` during a reconnect (fire `graceExpired`).
    private var graceTimers: [WindowID: Task<Void, Never>] = [:]
    /// The reconnect grace window before a stale (frozen-frame) viewer is torn down (SFU link blip).
    private static let reconnectGraceSeconds: UInt64 = 10
    /// The SHORT grace for a bare trackEnded while connected — long enough to catch a codec-
    /// renegotiation resubscribe (~1s, M11) or confirm a real sharer crash, short enough that a real
    /// crash tears the window down promptly (≤2s target).
    private static let renegotiationGraceSeconds: UInt64 = 2

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

    /// Surfaces this instance is locally sharing (window OR display capture services), keyed by
    /// windowID. Typed as the `ShareCaptureService` existential so window + display share uniformly.
    private var localCaptures: [WindowID: any ShareCaptureService] = [:]
    /// The kind (window/display) of each local share, so unshare updates the context correctly.
    private var localShareKinds: [WindowID: ShareKind] = [:]
    /// The structural share context this host publishes (D5). Updated to include a PENDING share
    /// BEFORE publishing it, so the new track gets the right codec (the ordering fix, latent #3).
    private var shareContext = ShareContext()
    /// Admitted target bitrate (bps) per local share, for uplink admission (M11).
    private var localShareBitrates: [WindowID: Double] = [:]

    /// Admission controller (M11 — revives dead code #4). Config reconciliation: the TYPE default for
    /// maxEncodeSessions stays 1 (conservative base-chip) pending the Phase-0(f) hardware
    /// measurement; the call-site override to 3 reflects that a base Apple-Silicon Mac sustains a few
    /// low-latency encode sessions (window + display mixes). uplink is ASSUMED 20 Mbps until measured.
    private let admission = AdmissionController(config: .init(maxEncodeSessions: 3))
    /// ASSUMED measured uplink (bps) until Phase-0(f) — labeled so it's obvious it's a placeholder.
    private static let assumedUplinkBps: Double = 20_000_000
    /// Whether a share was refused by admission (drives a visible alert in the UI).
    public private(set) var shareRefusedReason: String?

    // MARK: - Remote control (F4) — coordination-plane display state only (D12: authorization is
    // owner-side against trusted local state, NOT these flags).

    /// The participant currently driving one of MY shared windows (drives the "X is driving" badge).
    /// nil when nobody is remote-controlling. Display-only.
    public private(set) var activeDriver: ParticipantID?
    /// A pending control request awaiting the owner's consent (drives a consent prompt). Display-only.
    public private(set) var pendingControlRequest: ControlRequest?
    /// The R8 secure-input banner state (shown when secure input blocks injection while driving).
    public private(set) var secureInputBanner: SecureInputBanner = .none
    private var inputPump: InputPump?

    // MARK: - Collaborators

    private let transport = LiveKitTransport()
    private let windowManager = RemoteWindowManager()
    private let borderOverlay = ShareBorderOverlay()
    private var stateChannel: (any WireDataChannel)?
    private var cursorPump: CursorPump?

    private var launchJoin: DirectJoinParameters?
    private var launchJoinFired = false
    /// Optional CGWindowID to auto-share after joining (the --share-window-id automation path).
    private var autoShareWindowID: UInt32?
    /// Optional CGDirectDisplayID to auto-share after joining (--share-display-id / --share-main-display).
    private var autoShareDisplayID: CGDirectDisplayID?
    private var pumps: [Task<Void, Never>] = []

    public init(launchJoin: DirectJoinParameters? = nil, autoShareWindowID: UInt32? = nil,
                autoShareDisplayID: CGDirectDisplayID? = nil) {
        self.launchJoin = launchJoin
        self.autoShareWindowID = autoShareWindowID
        self.autoShareDisplayID = autoShareDisplayID
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
        // Display name (M10) → JWT `name` claim → participant.name for everyone incl. late joiners.
        let displayName = params.displayName
        // Dev path: mint a local HS256 token (#if DEBUG). Production uses TokenClient (M7).
        #if DEBUG
        let token = DevTokenMinter.mint(identity: identity, room: params.room, name: displayName)
        #else
        let token: String
        do { token = try await TokenClient.fetch(server: params.serverURL, room: params.room,
                                                 identity: identity, name: displayName) }
        catch { fail("token: \(error)"); return }
        #endif

        // Install the unified remote-track hook BEFORE connecting so we don't miss early
        // subscriptions. The descriptor carries the resolved ownerID (correct owner attribution) and
        // sourceKind; TrackClassifier routes it to a window share vs a camera tile vs ignore.
        await transport.setOnRemoteTrack { [weak self] descriptor, track in
            let classification = TrackClassifier.classify(
                name: descriptor.trackName, source: descriptor.sourceKind.trackSource)
            let owner = descriptor.ownerID
            let sid = descriptor.trackSID
            Task { @MainActor in
                guard let self else { return }
                switch classification {
                case .windowShare(let windowID):
                    self.addRemoteWindow(windowID: windowID, ownerHint: owner, track: track)
                case .camera:
                    if let owner { self.addCameraTrack(owner: owner, sid: sid, track: track) }
                case .ignore:
                    break
                }
            }
        }
        // Install the track-gone hook: a sharer/camera that stops/crashes/disconnects fires this, and
        // we close+purge the viewer window (frozen-ghost fix) or drop the camera tile.
        await transport.setOnTrackGone { [weak self] gone in
            let classification = TrackClassifier.classify(
                name: gone.trackName, source: gone.sourceKind.trackSource)
            let owner = gone.ownerID
            let sid = gone.trackSID
            Task { @MainActor in
                guard let self else { return }
                switch classification {
                case .windowShare(let windowID):
                    self.handleRemoteTrackGone(windowID: windowID)
                case .camera:
                    if let owner { self.removeCameraTrack(owner: owner, sid: sid) }
                case .ignore:
                    break
                }
            }
        }
        // Participant media state (M10): name/speaking/mic/camera pushed reactively for the tile strip.
        await transport.setOnParticipantMediaChanged { [weak self] states in
            Task { @MainActor in self?.applyParticipantMedia(states) }
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
            // Start the input pump (F4) on the reliable/ordered input channel. Owner-side injection is
            // gated behind the kTCCServicePostEvent grant (human step); the pump receives + surfaces
            // control requests now, and injects once the grant + strategy spike land.
            let input = try await transport.openDataChannel(.input)
            startInputPump(input)
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
            // Automation: auto-share a display if --share-display-id / --share-main-display was passed.
            if let displayID = autoShareDisplayID {
                autoShareDisplayID = nil
                shareDisplay(displayID: displayID)
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
        localShareKinds.removeAll()
        localShareBitrates.removeAll()
        shareContext = ShareContext()
        shareRefusedReason = nil
        borderOverlay.hide()
        isSharingDisplay = false
        await transport.disconnect()
        windowManager.closeAll()
        remoteWindows.removeAll()
        cameraTracks.removeAll()
        cameraTrackSIDs.removeAll()
        participantMedia = [:]
        displayNames = [:]
        for t in graceTimers.values { t.cancel() }
        graceTimers.removeAll()
        lifecycles.removeAll()
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
        inputPump = nil
        activeDriver = nil
        pendingControlRequest = nil
        secureInputBanner = .none
        showJoinSheet = true
    }

    // MARK: - Pumps

    private func startConnectionPump() {
        let stream = transport.connectionStates()
        pumps.append(Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { continue }
                self.mediaState = state
                self.applyMediaStateToLifecycles(state)
                if case .failed(let r) = state { self.fail(r) }
            }
        })
    }

    /// Broadcast the media link's reconnecting state to every open window's lifecycle so a track that
    /// drops mid-reconnect parks in `.stale` (frozen frame + badge) rather than tearing down (§3 M9).
    private func applyMediaStateToLifecycles(_ state: MediaConnectionState) {
        let reconnecting = (state == .reconnecting)
        for windowID in lifecycles.keys {
            feed(windowID, .transportReconnecting(reconnecting))
            remoteWindows[windowID]?.isReconnecting = reconnecting && (lifecycles[windowID]?.state == .stale)
        }
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
        // Belt-and-braces (§3 M9): anyone who left since the last set gets `ownerDisconnected` fed to
        // any window they own (a defensive path alongside trackGone — if the SDK dropped the track
        // events, the participant diff still tears their windows down) and is pruned from the mirror
        // WITHOUT bumping revision (receiver-local; the host stays the revision authority).
        let departed = transportParticipants.subtracting(ids)
        transportParticipants = ids
        for owner in departed {
            for (windowID, win) in remoteWindows where win.ownerID == owner {
                feed(windowID, .ownerDisconnected)
            }
            // Drop their camera tile too (M10).
            cameraTracks[owner] = nil
            cameraTrackSIDs[owner] = nil
            room.pruneParticipant(owner) // no revision bump
        }
        recomputeRoster()
        Task { [weak self] in await self?.refreshDisplayNames() }
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

    // MARK: - Remote control (F4)

    private func startInputPump(_ channel: any WireDataChannel) {
        // The owner-state + bounds providers are captured weakly via the pump's @Sendable closures.
        // NOTE: full owner-state (capability grants + real window bounds) is wired as consent lands;
        // for now the authorizer defaults to remote-control-DISABLED, so nothing injects until the
        // owner explicitly grants — the safe default (D12: Watch is default, master switch off).
        let pump = InputPump(
            channel: channel,
            localID: localParticipantID,
            ownerStateProvider: { InputAuthorizer.OwnerState(remoteControlEnabled: false) },
            boundsProvider: { _ in nil })
        self.inputPump = pump
        pumps.append(Task { @MainActor [weak self] in
            await pump.runInbound(onControlRequest: { req in
                self?.handleControlRequest(req)
            })
        })
        // Secure-input polling (R8): a debounced 1s tick updates the banner while someone is driving.
        pumps.append(Task { @MainActor [weak self] in
            let detector = SecureInputDetector()
            while !Task.isCancelled {
                let active = detector.isSecureInputActive()
                self?.updateSecureInputBanner(secureInputActive: active)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        })
    }

    private func handleControlRequest(_ req: ControlRequest) {
        switch req.action {
        case .request:
            // Only prompt if it targets one of MY windows.
            guard room.owner(of: req.windowID) == localParticipantID else { return }
            pendingControlRequest = req
        case .release:
            if activeDriver == req.participantID { activeDriver = nil }
            pendingControlRequest = nil
            updateSecureInputBanner(secureInputActive: false)
        }
    }

    /// Owner approves a pending control request → record the driver (display badge). The actual
    /// injection grant (enabling remoteControl + a .write capability) lands with the consent-UI wiring;
    /// this drives the "X is driving" badge and the request flow now.
    public func approveControlRequest() {
        guard let req = pendingControlRequest else { return }
        activeDriver = req.participantID
        pendingControlRequest = nil
    }

    public func denyControlRequest() {
        pendingControlRequest = nil
    }

    private func updateSecureInputBanner(secureInputActive: Bool) {
        secureInputBanner = SecureInputBanner.decide(
            secureInputActive: secureInputActive, someoneIsDriving: activeDriver != nil)
    }

    /// The display label for the current driver (for the "X is driving" badge), or nil.
    public var activeDriverLabel: String? {
        activeDriver.map { displayLabel(for: $0) }
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
            // A prompt unshare notification: drive the window's lifecycle removal (the authoritative
            // snapshot confirms it too, but this reacts without waiting for the next snapshot).
            if ev.action == .unshared, lifecycles[ev.windowID] != nil {
                feed(ev.windowID, .shareRemovedFromSnapshot)
            }
            // `shared` is handled when the track subscribes; the snapshot carries authoritative state.
        default:
            break
        }
    }

    /// Replace the mirrored room with `newRoom`, REPAIRING owner attribution and pause state on open
    /// viewer windows and feeding snapshot-removal events into the lifecycle. Only a JOINER applies
    /// foreign snapshots; the local sharer's own windows are driven by its capture.
    private func applyRoom(_ newRoom: RoomModel) {
        let previousShares = Set(room.shares.keys)
        room = newRoom
        recomputeRoster()

        // Owner + metadata repair: a track that subscribed before the first snapshot had a
        // placeholder owner/title; every snapshot repairs it so chrome recolors/retitles live.
        for (windowID, win) in remoteWindows {
            if let owner = newRoom.owner(of: windowID), owner != win.ownerID {
                win.ownerID = owner
                windowManager.refreshTitle(win)
            }
            if let info = newRoom.info(of: windowID) {
                let newTitle = info.title, newApp = info.appName, aspect = info.sourceAspectRatio
                if win.title != newTitle || win.appName != newApp { win.title = newTitle; win.appName = newApp; windowManager.refreshTitle(win) }
                if let aspect, win.aspectRatio != aspect { win.aspectRatio = aspect }
            }
            // Pause badge from broadcast state (previously ignored).
            win.isPaused = (newRoom.pauseState(of: windowID) == .paused)
        }

        // A share that disappeared from this authoritative snapshot → lifecycle removal.
        for windowID in previousShares where newRoom.owner(of: windowID) == nil {
            feed(windowID, .shareRemovedFromSnapshot)
        }
    }

    // MARK: - Remote windows (lifecycle-driven, M9)

    /// Feed one event into a window's lifecycle reducer and execute the resulting effects. The
    /// reducer holds ALL the correctness (grace parking, no-duplicate-window, soft/hard hide); this
    /// just runs the effects against the NSWindow layer + transport.
    private func feed(_ windowID: WindowID, _ event: RemoteWindowLifecycle.Event) {
        guard var lifecycle = lifecycles[windowID] else { return }
        let effects = lifecycle.reduce(event)
        lifecycles[windowID] = lifecycle
        execute(effects, for: windowID)
    }

    private func execute(_ effects: [RemoteWindowLifecycle.Effect], for windowID: WindowID) {
        for effect in effects {
            switch effect {
            case .openWindow:
                if let win = remoteWindows[windowID] { windowManager.open(win) }
            case .closeWindow:
                windowManager.close(windowID)
            case .unsubscribe:
                // Hard unsubscribe = zero downlink, no decode. Mark the entry inactive so the decode
                // budget and any thumbnail renderer treat it as not-decoding until it resubscribes.
                remoteWindows[windowID]?.isRenderingActive = false
                Task { await transport.setWindowTrackSubscribed(windowID: windowID, false) }
            case .resubscribe:
                Task { await transport.setWindowTrackSubscribed(windowID: windowID, true) }
            case .pauseRendering:
                remoteWindows[windowID]?.isRenderingActive = false
            case .resumeRendering:
                remoteWindows[windowID]?.isRenderingActive = true
            case .purge:
                purgeRemoteWindow(windowID)
            }
        }
    }

    private func addRemoteWindow(windowID: WindowID, ownerHint: ParticipantID?,
                                 track: JoeScreenLiveKit.RemoteVideoTrackRef) {
        // Reopen / reconnect resubscribe: the SDK re-delivered a track for a window whose entry we
        // still hold. Swap it in-place (no duplicate window) and let the reducer resume.
        if let existing = remoteWindows[windowID] {
            existing.track = track
            existing.isReconnecting = false
            existing.isRenderingActive = true // the track is back → decoding again (reopen/reconnect)
            windowManager.replaceContent(existing)
            cancelGrace(windowID)
            feed(windowID, .trackSubscribed)
            return
        }
        AppLog.info("remote track subscribed → opening native window for \(windowID)")
        // Owner attribution priority: authoritative snapshot > descriptor identity > windowID
        // (repaired by applyRoom). ShareInfo (if the snapshot already has it) seeds aspect/title.
        let owner = room.owner(of: windowID) ?? ownerHint ?? windowID
        let info = room.info(of: windowID)
        let win = RemoteVideoWindow(
            windowID: windowID, ownerID: owner, track: track,
            aspectRatio: info?.sourceAspectRatio, title: info?.title, appName: info?.appName)
        win.isPaused = (room.pauseState(of: windowID) == .paused)
        remoteWindows[windowID] = win
        lifecycles[windowID] = RemoteWindowLifecycle(
            reconnecting: mediaState == .reconnecting)
        transportParticipants.insert(owner)
        recomputeRoster()
        feed(windowID, .trackSubscribed) // → openWindow effect
    }

    // MARK: - Participant media (M10)

    /// Apply the reactive media-state snapshot from the transport, and fold any display names it
    /// carries into the name cache so `displayLabel` updates live on `didUpdateName` / late-join.
    private func applyParticipantMedia(_ states: [ParticipantID: ParticipantMediaState]) {
        participantMedia = states
        for (id, s) in states where s.displayName != nil {
            displayNames[id] = s.displayName
        }
    }

    /// Live media state for a participant (nil if unknown).
    public func mediaState(for id: ParticipantID) -> ParticipantMediaState? { participantMedia[id] }

    /// The remote camera track for a participant, if any.
    public func cameraTrack(for id: ParticipantID) -> JoeScreenLiveKit.RemoteVideoTrackRef? {
        cameraTracks[id]
    }

    /// The planned tile order + decode budget for the strip (self first, remotes name-then-UUID,
    /// cameras beyond the budget park as avatars; shares take priority). Pure `TileSubscriptionPlanner`.
    public var plannedTiles: [TileSubscriptionPlanner.Tile] {
        let me = localParticipantID
        let remotes = participants.subtracting(me.map { [$0] } ?? []).sorted { $0.uuidString < $1.uuidString }
        return TileSubscriptionPlanner.plan(
            selfID: me,
            remotes: remotes,
            displayName: { [weak self] in self?.displayNames[$0] },
            hasRenderableCamera: { [weak self] in self?.cameraTracks[$0] != nil },
            // Only windows actually decoding count against the budget — a user-closed (hard-
            // unsubscribed) or soft-hidden window consumes no decode/downlink.
            sharesDecoded: decodingShareCount)
    }

    /// Raise all shared windows owned by `owner` (tap a participant tile).
    public func focusSharesOf(owner: ParticipantID) {
        for (windowID, win) in remoteWindows where win.ownerID == owner {
            windowManager.focus(windowID)
        }
    }

    /// The remote video track backing a shared window's live thumbnail (M10) — a SECOND renderer on
    /// the already-held track (one decode, two renderers; adaptive-stream reports the max renderer
    /// size so the big window keeps its quality; R32 satisfied by construction). Nil if not (yet) open.
    public func remoteWindowTrack(_ windowID: WindowID) -> JoeScreenLiveKit.RemoteVideoTrackRef? {
        remoteWindows[windowID]?.track
    }

    /// The source aspect ratio of a shared window (for an aspect-true thumbnail), if known.
    public func remoteWindowAspect(_ windowID: WindowID) -> Double? {
        remoteWindows[windowID]?.aspectRatio
    }

    /// Whether a shared window is actively rendering (open, not soft-hidden). The share thumbnail
    /// must gate its SECOND renderer on this too: a soft-hidden (miniaturized/occluded) window
    /// detaches its big renderer so adaptive-stream stops SFU forwarding — a thumbnail renderer left
    /// attached would keep the stream flowing and defeat the R24/R32 soft-hide.
    public func isRemoteWindowRenderingActive(_ windowID: WindowID) -> Bool {
        remoteWindows[windowID]?.isRenderingActive ?? false
    }

    /// Count of shared windows ACTUALLY decoding right now (open AND rendering) — used for the decode
    /// budget. A user-closed window stays in `remoteWindows` (reopenable) but is hard-unsubscribed at
    /// the SFU (zero decode), so it must NOT count against the budget.
    private var decodingShareCount: Int {
        remoteWindows.values.filter { $0.isRenderingActive }.count
    }

    // MARK: - Camera tiles (M10)

    /// Record a remote participant's camera track for their tile. Keyed by owner; a newer SID for the
    /// same owner (camera re-enable / republish) replaces the prior one.
    private func addCameraTrack(owner: ParticipantID, sid: String, track: JoeScreenLiveKit.RemoteVideoTrackRef) {
        cameraTracks[owner] = track
        cameraTrackSIDs[owner] = sid
        transportParticipants.insert(owner)
        recomputeRoster()
    }

    /// Drop a remote participant's camera track when its SID goes away (only if it's still the
    /// current one — a stale gone for a replaced SID is ignored).
    private func removeCameraTrack(owner: ParticipantID, sid: String) {
        guard cameraTrackSIDs[owner] == sid else { return }
        cameraTracks[owner] = nil
        cameraTrackSIDs[owner] = nil
    }

    /// A remote sharer's track went away (stop / crash / codec renegotiation republish). The reducer
    /// parks it `.stale` (frozen frame); we arm a grace timer — a long one during an SFU-link
    /// reconnect (blip), a short one otherwise (catch a renegotiation resubscribe / confirm a crash).
    private func handleRemoteTrackGone(windowID: WindowID) {
        guard lifecycles[windowID] != nil else { return }
        feed(windowID, .trackGone(.trackEnded))
        if lifecycles[windowID]?.state == .stale {
            let reconnecting = (mediaState == .reconnecting)
            // Show the "Reconnecting…" badge only for a real link reconnect; a renegotiation swap just
            // freezes briefly (no alarming badge).
            remoteWindows[windowID]?.isReconnecting = reconnecting
            armGrace(windowID, seconds: reconnecting ? Self.reconnectGraceSeconds : Self.renegotiationGraceSeconds)
        }
    }

    /// The user closed the viewer window (NSWindowDelegate.windowWillClose) — keep a reopenable entry.
    /// Called by `RemoteWindowManager`'s per-window delegate (same app module).
    func remoteWindowDelegateEvent(_ windowID: WindowID, _ event: RemoteWindowDelegate.Event) {
        switch event {
        case .userClosed:
            // The window is already closing; execute the reducer WITHOUT a redundant closeWindow (the
            // manager cut the delegate before a programmatic close, so this only fires on a real user
            // close). We still cut downlink + keep the entry.
            feed(windowID, .userClosed)
        case .miniaturized(let value):
            feed(windowID, .miniaturized(value))
        case .occluded(let value):
            feed(windowID, .occluded(value))
        }
    }

    /// Reopen a user-closed viewer window (SharedWindowTile / Window menu). Re-subscribes; the new
    /// track routes into the existing entry via `addRemoteWindow`'s reopen branch.
    public func reopenRemoteWindow(_ windowID: WindowID) {
        guard lifecycles[windowID]?.state == .closedByUser else { return }
        feed(windowID, .userReopened) // → resubscribe effect
    }

    /// Terminal purge: drop the entry, lifecycle, timers. The window itself is closed by the
    /// closeWindow effect (or was already closing on a user-close path).
    private func purgeRemoteWindow(_ windowID: WindowID) {
        remoteWindows[windowID] = nil
        lifecycles[windowID] = nil
        cancelGrace(windowID)
    }

    // MARK: - Reconnect / renegotiation grace

    private func armGrace(_ windowID: WindowID, seconds: UInt64) {
        cancelGrace(windowID)
        graceTimers[windowID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.feed(windowID, .graceExpired)
        }
    }

    private func cancelGrace(_ windowID: WindowID) {
        graceTimers[windowID]?.cancel()
        graceTimers[windowID] = nil
    }

    /// The window manager asks for a window's cascade indices (owner index among current owners,
    /// window index within that owner) so `WindowCascade` places it deterministically.
    func cascadeIndices(for windowID: WindowID, owner: ParticipantID) -> (ownerIndex: Int, windowIndex: Int) {
        // Owners currently rendered, sorted for a stable index.
        let owners = Set(remoteWindows.values.map { $0.ownerID }).sorted { $0.uuidString < $1.uuidString }
        let ownerIndex = owners.firstIndex(of: owner) ?? 0
        let ownerWindows = remoteWindows.keys
            .filter { remoteWindows[$0]?.ownerID == owner }
            .sorted { $0.uuidString < $1.uuidString }
        let windowIndex = ownerWindows.firstIndex(of: windowID) ?? 0
        return (ownerIndex, windowIndex)
    }

    // MARK: - Window menu / focus actions

    /// Whether newly-opened remote windows steal focus ("Follow New Shares", session pref).
    public var followNewShares: Bool = false

    public func focusRemoteWindow(_ windowID: WindowID) { windowManager.focus(windowID) }
    public func bringAllSharedWindowsToFront() { windowManager.bringAllToFront() }
    public func setFollowNewShares(_ follow: Bool) {
        followNewShares = follow
        windowManager.followNewShares = follow
    }
    public func setAlwaysOnTop(_ windowID: WindowID, _ onTop: Bool) {
        windowManager.setAlwaysOnTop(windowID, onTop)
    }

    /// Whether a window is in the user-closed state (drives the tile's Reopen vs Focus button).
    public func isRemoteWindowClosed(_ windowID: WindowID) -> Bool {
        lifecycles[windowID]?.state == .closedByUser
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
        // The picker (SCContentSharingPicker) calls back with the chosen window OR display (M11).
        SharePicker.shared.present(onPick: { [weak self] pick in
            Task { @MainActor in
                switch pick {
                case .window(let cgWindowID): self?.shareWindow(cgWindowID: cgWindowID)
                case .display(let displayID): self?.shareDisplay(displayID: displayID)
                }
            }
        }, onAmbiguous: { [weak self] in
            Task { @MainActor in
                self?.shareRefusedReason = "Couldn't identify the selected screen. Please pick it again."
            }
        })
    }

    /// Share a whole display by CGDirectDisplayID (the picker callback AND the --share-display-id /
    /// --share-main-display automation bypass land here). Full capture path lands in M11.5.
    public func shareDisplay(displayID: CGDirectDisplayID) {
        Task { await startSharingDisplay(displayID: displayID) }
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
        // Encode-session cap is knowable up front — refuse BEFORE touching the codec context so a
        // capped share never renegotiates live tracks (no VP9→H.264→VP9 flicker).
        if let refusal = encodeCapRefusal() { shareRefusedReason = refusal; return }

        let windowID = WindowID()
        let capture = WindowCaptureService(windowID: windowID)
        localCaptures[windowID] = capture
        localShareKinds[windowID] = .window

        // Codec-ordering fix (latent #3): update the share context to INCLUDE this pending window
        // BEFORE publishing, so the transport (which now builds publish options at completePublish,
        // after the first frame) selects the right structural codec for the new track (D5).
        let pending = shareContext.adding(.window)
        await pushShareContext(pending)

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
                    case .ended: self?.unshare(windowID)
                    case .stopped: self?.unshare(windowID)
                    case .resized(let w, let h): self?.updateShareDimensions(windowID, pixelWidth: w, pixelHeight: h)
                    case .frame: break
                    }
                }
            })
            try await capture.start(cgWindowID: cgWindowID, sink: sink)
            AppLog.info("capture started for cgWindowID=\(cgWindowID); broadcasting share")
            let info = await capture.shareInfo

            // Uplink admission (M11): compute this share's target bitrate and check it fits alongside
            // the existing shares. Degrade the whole set uniformly if needed; refuse (tear down, no
            // dangling capture) if it won't fit even at the floor.
            if !(await admitShare(windowID: windowID, kind: .window, info: info)) {
                await teardownFailedShare(windowID)
                return
            }

            // Commit the context (the share is now live).
            shareContext = pending
            // Update authoritative room + broadcast.
            room.addShare(windowID, owner: me)
            // Populate the advisory ShareInfo (title/app/source pixels) captured at start so receivers
            // can title + aspect-size their viewer window before the first frame (M9).
            if let info { room.setShareInfo(info, window: windowID) }
            broadcastState()
            broadcastShareEvent(.shared, windowID: windowID, owner: me, info: room.info(of: windowID))
        } catch {
            AppLog.error("startSharing failed: \(String(describing: error))")
            await teardownFailedShare(windowID)
        }
    }

    /// The structural encode-session cap check, knowable UP FRONT (before capture/pixels). Gating on
    /// it before `pushShareContext` means a share refused purely by the cap never renegotiates (and
    /// then un-renegotiates) live tracks — no flicker. Returns a refusal message if capped, else nil.
    private func encodeCapRefusal() -> String? {
        // currentWindowCount = shares already live; the cap refuses when +1 would exceed maxEncodeSessions.
        let decision = admission.admitShare(
            existingBitrates: localShareBitrates.values.map { $0 },
            requestedBitrate: ShareBitratePolicy.floorBps,
            measuredUplinkBps: .greatestFiniteMagnitude, // ignore bandwidth — only the encode cap here
            peerCount: participants.count, topology: .sfu)
        if case .refuseAtCapacity(.encodeSessionCap(let max)) = decision {
            return Self.refusalMessage(.encodeSessionCap(max: max))
        }
        return nil
    }

    /// Run uplink admission for a pending share; on `.degrade` uniformly rescale existing shares'
    /// bitrates; set the admitted bitrate on the transport. Returns false if REFUSED (with a visible
    /// reason set). Screen-content bitrate comes from the source pixel dims via ShareBitratePolicy.
    private func admitShare(windowID: WindowID, kind: ShareKind, info: ShareInfo?) async -> Bool {
        let w = info?.sourcePixelWidth ?? 1920
        let h = info?.sourcePixelHeight ?? 1080
        let requested = ShareBitratePolicy.bitrate(pixelWidth: w, pixelHeight: h)
        let existing = localShareBitrates.values.map { $0 }
        let decision = admission.admitShare(
            existingBitrates: existing, requestedBitrate: requested,
            measuredUplinkBps: Self.assumedUplinkBps, peerCount: participants.count, topology: .sfu)
        switch decision {
        case .admit(let bitrate):
            localShareBitrates[windowID] = bitrate
            await transport.setShareBitrate(windowID: windowID, bps: bitrate)
            shareRefusedReason = nil
            return true
        case .degrade(let perWindow):
            // Uniformly rescale EVERY share (existing + new) to the common fitting bitrate. The new
            // share picks it up at publish; ALREADY-LIVE shares whose bitrate dropped must be
            // republished so the degrade actually protects the uplink (setShareBitrate alone only
            // affects the next publish).
            let liveWindowsToRepublish = localShareBitrates.keys.filter { $0 != windowID && localShareBitrates[$0] != perWindow }
            localShareBitrates[windowID] = perWindow
            for id in localShareBitrates.keys { localShareBitrates[id] = perWindow }
            for id in localShareBitrates.keys { await transport.setShareBitrate(windowID: id, bps: perWindow) }
            if !liveWindowsToRepublish.isEmpty {
                await transport.republishForBitrateChange(windowIDs: Array(liveWindowsToRepublish))
            }
            shareRefusedReason = nil
            return true
        case .refuseAtCapacity(let reason):
            shareRefusedReason = Self.refusalMessage(reason)
            AppLog.error("share refused by admission: \(reason)")
            return false
        }
    }

    private static func refusalMessage(_ reason: AdmissionController.RefuseReason) -> String {
        switch reason {
        case .encodeSessionCap(let max):
            return "Can't share another surface: this Mac's encoder is at capacity (max \(max) concurrent shares)."
        case .uplinkExhausted:
            return "Can't share another surface: your upload bandwidth is fully committed. Unshare something first."
        }
    }

    /// Tear down a share that failed to start or was refused — no dangling capture, context rolled back.
    private func teardownFailedShare(_ windowID: WindowID) async {
        if let capture = localCaptures[windowID] { await capture.stop() }
        localCaptures[windowID] = nil
        localShareKinds[windowID] = nil
        localShareBitrates[windowID] = nil
        await transport.unpublishVideoTrack(for: windowID)
        await pushShareContext(shareContext) // exclude the failed share
    }

    /// Dismiss the admission-refusal alert.
    public func dismissShareRefusal() { shareRefusedReason = nil }

    /// Start sharing a whole display (M11). One display share per sharer in v1 (window+display mix
    /// allowed; a SECOND display is refused with a visible reason — DECISIONS §5.3). The
    /// DisplayCaptureService captures with the hall-of-mirrors filter; naming uses display:<uuid>.
    private func startSharingDisplay(displayID: CGDirectDisplayID) async {
        guard let me = localParticipantID else { return }
        // One-display-per-sharer: refuse a second display (window+display is fine).
        if shareContext.displayShareCount >= 1 {
            shareRefusedReason = "You can share only one screen at a time. Stop the current screen share first."
            return
        }
        // Encode-cap refusal up front (before the codec context flips live tracks → no flicker).
        if let refusal = encodeCapRefusal() { shareRefusedReason = refusal; return }
        let hasAccess = CGPreflightScreenCaptureAccess()
        AppLog.info("startSharingDisplay displayID=\(displayID) screenCaptureAccess=\(hasAccess)")
        if !hasAccess { _ = CGRequestScreenCaptureAccess() }

        let windowID = WindowID()
        let capture = DisplayCaptureService(windowID: windowID, displayID: displayID)
        localCaptures[windowID] = capture
        localShareKinds[windowID] = .display

        // Codec-ordering fix + structural D5: a display share forces H.264 for ALL share tracks.
        // Update the context to INCLUDE the pending display BEFORE publish; the transport
        // renegotiates any live VP9 window track to H.264 as part of updateShareContext.
        let pending = shareContext.adding(.display)
        await pushShareContext(pending)

        do {
            let sink = try await transport.publishVideoTrack(for: windowID, kind: .display)
            let events = await capture.events()
            pumps.append(Task { @MainActor [weak self] in
                for await event in events {
                    switch event {
                    case .paused: self?.setLocalPause(windowID, .paused)
                    case .resumed: self?.setLocalPause(windowID, .live)
                    case .ended: self?.unshare(windowID)
                    case .stopped: self?.unshare(windowID)
                    case .resized(let w, let h): self?.updateShareDimensions(windowID, pixelWidth: w, pixelHeight: h)
                    case .frame: break
                    }
                }
            })
            try await capture.start(sink: sink)
            let info = await capture.shareInfo

            if !(await admitShare(windowID: windowID, kind: .display, info: info)) {
                await teardownFailedShare(windowID)
                return
            }

            shareContext = pending
            room.addShare(windowID, owner: me)
            if let info { room.setShareInfo(info, window: windowID) }
            // Show the sharer's screen-border affordance.
            borderOverlay.show(displayID: displayID)
            isSharingDisplay = true
            broadcastState()
            broadcastShareEvent(.shared, windowID: windowID, owner: me, info: room.info(of: windowID))
        } catch {
            AppLog.error("startSharingDisplay failed: \(String(describing: error))")
            await teardownFailedShare(windowID)
        }
    }

    /// Whether this instance is currently sharing a display (drives the "Sharing Display" chip).
    public private(set) var isSharingDisplay = false

    /// Stop the current display share (control-bar chip / stop button).
    public func stopDisplayShare() {
        guard let id = localShareKinds.first(where: { $0.value == .display })?.key else { return }
        unshare(id)
    }

    /// Push a share context to the transport (windowCount + wholeDisplay) — the transport's
    /// CodecSelector reads it when building publish options at completePublish (D5).
    private func pushShareContext(_ context: ShareContext) async {
        await transport.updateShareContext(
            windowCount: context.totalShareCount, wholeDisplay: context.wholeDisplay)
    }

    public func unshare(_ windowID: WindowID) {
        Task { await unshareAsync(windowID) }
    }

    private func unshareAsync(_ windowID: WindowID) async {
        guard let me = localParticipantID, room.owner(of: windowID) == me else { return }
        if let capture = localCaptures[windowID] { await capture.stop() }
        localCaptures[windowID] = nil
        let kind = localShareKinds[windowID] ?? .window
        localShareKinds[windowID] = nil
        localShareBitrates[windowID] = nil
        await transport.unpublishVideoTrack(for: windowID)
        room.removeShare(windowID)
        // Update the structural context (removing this share) so any remaining tracks reflect it (a
        // window track may renegotiate VP9↔H.264 as the display share leaves).
        shareContext = shareContext.removing(kind)
        await pushShareContext(shareContext)
        // Display-share teardown: hide the sharer border + clear the chip.
        if kind == .display {
            borderOverlay.hide()
            isSharingDisplay = shareContext.displayShareCount > 0
        }
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

    private func broadcastShareEvent(_ action: ShareEvent.Action, windowID: WindowID,
                                     owner: ParticipantID, info: ShareInfo? = nil) {
        guard let channel = stateChannel else { return }
        let ev = ShareEvent(action: action, windowID: windowID, ownerID: owner,
                            revision: room.revision, info: info)
        guard let env = try? WireCodec.pack(ev, sender: owner),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    /// A local share's source window settled at a new size (post-stabilizer). Update the advisory
    /// ShareInfo dimensions in the authoritative room and re-broadcast so receivers re-aspect.
    private func updateShareDimensions(_ windowID: WindowID, pixelWidth: Int, pixelHeight: Int) {
        guard room.owner(of: windowID) == localParticipantID,
              var info = room.info(of: windowID) else { return }
        info.sourcePixelWidth = pixelWidth
        info.sourcePixelHeight = pixelHeight
        if room.setShareInfo(info, window: windowID) { broadcastState() }
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

    // MARK: - Display names (M10)

    /// Cached LiveKit `participant.name` per participant (JWT `name` claim). Populated on participant
    /// changes; the reactive per-event push arrives with M10.3's ParticipantMediaState hook.
    public private(set) var displayNames: [ParticipantID: String] = [:]

    /// The best label for a participant: their display name if set, else the 4-char UUID fallback.
    public func displayLabel(for id: ParticipantID) -> String {
        if let name = displayNames[id], !name.isEmpty { return name }
        return shortLabel(for: id)
    }

    /// Refresh the display-name cache for the current participant set from the transport.
    private func refreshDisplayNames() async {
        var names: [ParticipantID: String] = [:]
        for id in transportParticipants {
            if let name = await transport.displayName(for: id) { names[id] = name }
        }
        displayNames = names
    }
}
