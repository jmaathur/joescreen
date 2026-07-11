import SwiftUI
import Observation
import JoeScreenKit
import JoeScreenLiveKit

/// The iOS viewer's app state (M8). Connects to a session via Direct Session Mode and renders every
/// remote shared window as a zoomable video pane. Viewer + voice only — no capture, no input (R6).
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

    private let transport = LiveKitTransport()
    private var stateChannel: (any WireDataChannel)?
    private var pumps: [Task<Void, Never>] = []

    public init() {}

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
        #if DEBUG
        let token = DevTokenMinter.mint(identity: params.identity, room: params.room, name: params.displayName)
        #else
        let token: String
        do { token = try await TokenClient.fetch(server: params.serverURL, room: params.room,
                                                 identity: params.identity, name: params.displayName) }
        catch { phase = .failed("token: \(error)"); return }
        #endif

        await transport.setOnRemoteTrack { [weak self] descriptor, track in
            // iOS is a viewer of WINDOW shares (+ M11 display shares); camera tiles are macOS-only
            // for now. ShareTrackName parses window:/display: names and ignores camera/garbage.
            guard let windowID = ShareTrackName.windowID(from: descriptor.trackName) else { return }
            Task { @MainActor in self?.addRemoteTrack(windowID: windowID, track: track) }
        }
        startConnectionPump()

        do {
            try await transport.connect(.init(serverURL: params.serverURL, authToken: token))
            try await transport.openAllDataChannels()
            let state = try await transport.openDataChannel(.state)
            stateChannel = state
            startStatePump(state)
            // Voice: enable the mic on join (iOS is a first-class voice participant).
            try? await transport.setMicrophone(enabled: true)
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
        phase = .idle
        showJoinSheet = true
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
