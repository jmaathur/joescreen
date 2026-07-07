import SwiftUI
import Observation
import JoeScreenKit
import JoeScreenLiveKit
import JoeScreenCaptureMac
import ScreenCaptureKit

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

        // Install the remote-track hook BEFORE connecting so we don't miss early subscriptions.
        await transport.setOnTrackSubscribed { [weak self] trackName, track in
            guard let windowID = LiveKitTransport.windowID(fromTrackName: trackName) else { return }
            Task { @MainActor in self?.addRemoteWindow(windowID: windowID, track: track) }
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
            // Start the cursor pump (M6).
            let cursor = try await transport.openDataChannel(.cursor)
            let pump = CursorPump(channel: cursor, localID: localParticipantID)
            self.cursorPump = pump
            windowManager.cursorPump = pump
            startCursorInPump(pump)
            phase = .inCall
            // Seed the local participant into the roster immediately.
            if let me = localParticipantID { participants.insert(me) }
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
        phase = .idle
        participants = []
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
        // LiveKit exposes participant connect/disconnect via the transport's identity map; we derive
        // the roster from remote-window owners + local + any explicitly seen. For M4 the roster is
        // driven by state snapshots (owners) + local; a fuller participant stream is an M7 concern.
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
        // Roster: everyone who owns a share, plus us.
        var roster = Set(newRoom.shares.values)
        if let me = localParticipantID { roster.insert(me) }
        participants.formUnion(roster)
        // Close any remote viewer window whose share disappeared.
        for windowID in remoteWindows.keys where newRoom.owner(of: windowID) == nil {
            removeRemoteWindowIfForeign(windowID)
        }
    }

    // MARK: - Remote windows

    private func addRemoteWindow(windowID: WindowID, track: JoeScreenLiveKit.RemoteVideoTrackRef) {
        AppLog.info("remote track subscribed → opening native window for \(windowID)")
        let owner = room.owner(of: windowID) ?? windowID // fallback owner id for coloring
        let win = RemoteVideoWindow(windowID: windowID, ownerID: owner, track: track)
        remoteWindows[windowID] = win
        if let me = localParticipantID { participants.insert(me) }
        participants.insert(owner)
        windowManager.open(win)
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
