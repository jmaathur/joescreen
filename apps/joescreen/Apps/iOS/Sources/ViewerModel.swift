import SwiftUI
import Observation
import AVFoundation
import Combine
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// The iOS viewer's app state (M8, extended). Connects to a session via Direct Session Mode, renders
/// every remote shared window, and lets the user publish their **mic** and **camera** (toggleable,
/// mirroring the desktop). iOS still cannot be remote-CONTROLLED and shares its screen full-screen
/// only (R6) — the camera here is a normal `.camera` video bubble like the Mac's.
@MainActor
@Observable
public final class ViewerModel {

    public enum Phase: Equatable { case idle, connecting, inCall, failed(String) }

    public private(set) var phase: Phase = .idle
    public private(set) var joinParameters: DirectJoinParameters?
    public private(set) var localParticipantID: ParticipantID?
    public private(set) var mediaState: MediaConnectionState = .disconnected
    public private(set) var room = RoomModel()
    public private(set) var participants: Set<ParticipantID> = []
    public var showJoinSheet = true

    /// Remote video tracks to render, keyed by windowID (parsed from the track name).
    public private(set) var remoteTracks: [WindowID: RemoteVideoTrackRef] = [:]
    /// Owner per window (for chrome color), from the mirrored room state.
    public private(set) var owners: [WindowID: ParticipantID] = [:]

    // MARK: - Local media (mic + camera)

    /// Whether the local mic is currently LIVE (published + unmuted). Drives the mic toggle.
    public private(set) var micEnabled = false
    /// Whether the local camera is currently LIVE. Drives the camera toggle.
    public private(set) var cameraEnabled = false
    /// The local camera track for the self-preview (non-nil exactly while the camera is on).
    public private(set) var localCameraTrack: VideoTrack?
    /// Whether the local whole-screen broadcast is currently LIVE. Drives the "Share Screen" toggle.
    /// iOS can only share the WHOLE screen (R6), via a ReplayKit broadcast extension; the desktop's
    /// window/display picker becomes this single toggle.
    public private(set) var screenShareEnabled = false
    /// Whether to join the next call muted (persisted; default false). Mirrors the desktop pref.
    public var joinMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "JoeScreen.joinMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "JoeScreen.joinMuted") }
    }

    private let transport = LiveKitTransport()
    private var stateChannel: (any WireDataChannel)?
    private var pumps: [Task<Void, Never>] = []

    /// Observes LiveKit's broadcast state (ReplayKit start/stop) to publish/unpublish the screen share.
    private var broadcastCancellable: AnyCancellable?
    /// The stable WindowID for our whole-screen broadcast share (minted once per broadcast).
    private var broadcastWindowID: WindowID?

    public init() {
        // The SDK auto-publishes a broadcast track named `screen_share` when broadcasting starts; we
        // publish it OURSELVES with a `display:<uuid>` name (so viewers recognize it), so disable the
        // auto-path. Then mirror the real ReplayKit broadcast state into `screenShareEnabled`.
        BroadcastManager.shared.shouldPublishTrack = false
        broadcastCancellable = BroadcastManager.shared.isBroadcastingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isBroadcasting in
                Task { @MainActor in await self?.broadcastStateChanged(isBroadcasting) }
            }
    }

    // MARK: - Join

    public func requestJoin(_ params: DirectJoinParameters) {
        joinParameters = params
        localParticipantID = params.participantID
        showJoinSheet = false
        phase = .connecting
        Task { await connect(params) }
    }

    public func leave() { Task { await teardown() } }

    private func connect(_ params: DirectJoinParameters) async {
        // Resolve (token, SFU URL): DEBUG mints locally + dials the URL as-is; RELEASE fetches from the
        // token server, which returns the authoritative SFU URL to dial.
        let token: String
        let sfuURL: URL
        #if DEBUG
        token = DevTokenMinter.mint(identity: params.identity, room: params.room, name: params.displayName)
        sfuURL = params.serverURL
        #else
        do {
            let creds = try await TokenClient.fetch(server: params.serverURL, room: params.room,
                                                    identity: params.identity, name: params.displayName)
            token = creds.token
            sfuURL = creds.sfuURL
        } catch { phase = .failed("token: \(error)"); return }
        #endif

        await transport.setOnRemoteTrack { [weak self] descriptor, track in
            // iOS is a viewer of WINDOW shares (+ M11 display shares); camera tiles are macOS-only
            // for now. ShareTrackName parses window:/display: names and ignores camera/garbage.
            guard let windowID = ShareTrackName.windowID(from: descriptor.trackName) else { return }
            Task { @MainActor in self?.addRemoteTrack(windowID: windowID, track: track) }
        }
        startConnectionPump()

        do {
            try await transport.connect(.init(serverURL: sfuURL, authToken: token))
            try await transport.openAllDataChannels()
            let state = try await transport.openDataChannel(.state)
            stateChannel = state
            startStatePump(state)
            // Voice: enable the mic on join unless the user chose to join muted.
            try? await transport.setMicrophone(enabled: !joinMuted)
            micEnabled = await transport.isMicrophoneEnabled()
            phase = .inCall
            if let me = localParticipantID { participants.insert(me) }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func teardown() async {
        for t in pumps { t.cancel() }
        pumps.removeAll()
        await transport.disconnect()
        remoteTracks.removeAll()
        owners.removeAll()
        room = RoomModel()
        participants = []
        localParticipantID = nil
        mediaState = .disconnected
        micEnabled = false
        cameraEnabled = false
        localCameraTrack = nil
        usingFrontCamera = true
        // Stop any active whole-screen broadcast on leave (the SDK unpublishes when it ends too).
        if BroadcastManager.shared.isBroadcasting { BroadcastManager.shared.requestStop() }
        await transport.unpublishBroadcastScreenShare()
        broadcastWindowID = nil
        screenShareEnabled = false
        phase = .idle
        showJoinSheet = true
    }

    // MARK: - Mic + camera toggles (mirrors the desktop control bar)

    /// Which camera to capture from (front by default, like a selfie). Flip toggles it.
    private var usingFrontCamera = true

    /// Toggle the mic. LiveKit mutes rather than unpublishes, so read the live state back.
    public func toggleMic() {
        let target = !micEnabled
        micEnabled = target // optimistic
        Task {
            try? await transport.setMicrophone(enabled: target)
            micEnabled = await transport.isMicrophoneEnabled()
        }
    }

    /// Toggle the camera. Enabling preflights camera TCC (deterministic system prompt) and publishes
    /// a `.camera` track; the local track drives the self-preview.
    public func toggleCamera() {
        let target = !cameraEnabled
        Task {
            if target {
                guard await Self.ensureCameraAccess() else { return } // denied → stay off
            }
            do {
                try await transport.setCamera(enabled: target, deviceID: cameraDeviceID())
            } catch {
                return
            }
            cameraEnabled = await transport.isCameraPublished()
            localCameraTrack = cameraEnabled ? await transport.localCameraVideoTrack() : nil
        }
    }

    /// Flip between the front and back camera (only meaningful while the camera is on).
    public func flipCamera() {
        guard cameraEnabled else { usingFrontCamera.toggle(); return }
        usingFrontCamera.toggle()
        Task {
            try? await transport.setCamera(enabled: true, deviceID: cameraDeviceID())
            localCameraTrack = await transport.localCameraVideoTrack()
        }
    }

    /// The AVCaptureDevice uniqueID for the currently-selected (front/back) camera, or nil for default.
    private func cameraDeviceID() -> String? {
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
            .devices.first?.uniqueID
    }

    /// Preflight camera TCC so the system prompt fires deterministically. Returns whether authorized.
    private static func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Screen share (whole-screen broadcast; iOS's analog of the desktop window/display picker)

    /// Toggle the whole-screen broadcast. Starting shows the system broadcast picker (the user must
    /// tap "Start Broadcast"); stopping ends it. The actual publish/unpublish happens in
    /// `broadcastStateChanged`, driven by the REAL ReplayKit state — tapping here is only a request.
    public func toggleScreenShare() {
        if BroadcastManager.shared.isBroadcasting {
            BroadcastManager.shared.requestStop()
        } else {
            BroadcastManager.shared.requestActivation()
        }
    }

    /// React to the real ReplayKit broadcast state: publish our `display:<uuid>` share when it starts,
    /// unpublish when it stops. `screenShareEnabled` follows the true state (not the tap), so a user
    /// who cancels the system picker never shows as "sharing".
    private func broadcastStateChanged(_ isBroadcasting: Bool) async {
        if isBroadcasting {
            let windowID = broadcastWindowID ?? WindowID()
            broadcastWindowID = windowID
            do {
                try await transport.publishBroadcastScreenShare(windowID: windowID)
                screenShareEnabled = true
            } catch {
                screenShareEnabled = false
            }
        } else {
            await transport.unpublishBroadcastScreenShare()
            broadcastWindowID = nil
            screenShareEnabled = false
        }
    }

    // MARK: - Pumps

    private func startConnectionPump() {
        let stream = transport.connectionStates()
        pumps.append(Task { @MainActor [weak self] in
            for await state in stream {
                self?.mediaState = state
                if case .failed(let r) = state { self?.phase = .failed(r) }
            }
        })
    }

    private func startStatePump(_ channel: any WireDataChannel) {
        let incoming = channel.incoming()
        pumps.append(Task { @MainActor [weak self] in
            for await data in incoming { self?.applyStatePayload(data) }
        })
    }

    private func applyStatePayload(_ data: Data) {
        guard let env = try? WireCodec.decode(data), let kind = env.kind else { return }
        switch kind {
        case .roomSnapshot:
            guard let snap = try? WireCodec.unpack(env, as: RoomSnapshot.self) else { return }
            if snap.model.revision > room.revision || room.revision == 0 { applyRoom(snap.model) }
        case .shareEvent:
            guard let ev = try? WireCodec.unpack(env, as: ShareEvent.self) else { return }
            if ev.action == .unshared { remoteTracks[ev.windowID] = nil; owners[ev.windowID] = nil }
        default: break
        }
    }

    private func applyRoom(_ newRoom: RoomModel) {
        room = newRoom
        for (win, owner) in newRoom.shares { owners[win] = owner }
        var roster = Set(newRoom.shares.values)
        if let me = localParticipantID { roster.insert(me) }
        participants.formUnion(roster)
        // Drop tracks whose share disappeared.
        for win in remoteTracks.keys where newRoom.owner(of: win) == nil {
            remoteTracks[win] = nil
            owners[win] = nil
        }
    }

    private func addRemoteTrack(windowID: WindowID, track: RemoteVideoTrackRef) {
        remoteTracks[windowID] = track
        if let owner = room.owner(of: windowID) { owners[windowID] = owner }
        if let me = localParticipantID { participants.insert(me) }
    }

    // MARK: - Helpers

    public var sortedTracks: [(window: WindowID, track: RemoteVideoTrackRef)] {
        remoteTracks.keys.sorted { $0.uuidString < $1.uuidString }
            .compactMap { win in remoteTracks[win].map { (win, $0) } }
    }

    public func color(for id: ParticipantID) -> Color {
        let c = ParticipantColor.components(for: id)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    public func owner(of window: WindowID) -> ParticipantID {
        owners[window] ?? window
    }
}
