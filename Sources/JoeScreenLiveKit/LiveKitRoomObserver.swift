import Foundation
import LiveKit
import JoeScreenKit

/// Bridges LiveKit's `@objc RoomDelegate` callbacks into async handlers on the `LiveKitTransport`
/// actor. LiveKit exposes events ONLY through this delegate at 2.15.1 (no public async-sequence
/// API), so we convert delegate → actor calls here and the actor fans them out to `AsyncStream`s.
///
/// Must be an `NSObject` because `RoomDelegate` is an `@objc` protocol with `@objc optional` methods.
/// Every callback hops onto the actor via an unstructured `Task`; the actor serializes them.
final class LiveKitRoomObserver: NSObject, RoomDelegate, Sendable {
    /// Weak back-reference to avoid a retain cycle (the transport holds the observer AND the room,
    /// which holds the observer as a delegate).
    private weak var transport: LiveKitTransport?

    init(transport: LiveKitTransport) {
        self.transport = transport
        super.init()
    }

    // MARK: - Connection state

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState,
              from oldConnectionState: ConnectionState) {
        let mapped = LiveKitRoomObserver.map(connectionState)
        Task { [weak transport] in await transport?.handleConnectionState(mapped) }
    }

    // MARK: - Participants

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        Task { [weak transport] in await transport?.handleParticipantConnected(identity: identity) }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        Task { [weak transport] in await transport?.handleParticipantDisconnected(identity: identity) }
    }

    // MARK: - Tracks

    func room(_ room: Room, participant: RemoteParticipant,
              didSubscribeTrack publication: RemoteTrackPublication) {
        let identity = participant.identity?.stringValue
        let name = publication.name
        // Capture the track reference now; the actor attaches a renderer if it's a video track.
        let videoTrack = publication.track as? RemoteVideoTrack
        Task { [weak transport] in
            await transport?.handleTrackSubscribed(identity: identity, trackName: name, videoTrack: videoTrack)
        }
    }

    func room(_ room: Room, participant: RemoteParticipant,
              didUnsubscribeTrack publication: RemoteTrackPublication) {
        let name = publication.name
        Task { [weak transport] in await transport?.handleTrackUnsubscribed(trackName: name) }
    }

    // MARK: - Data

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        Task { [weak transport] in await transport?.handleData(data, topic: topic) }
    }

    // MARK: - Mapping

    static func map(_ state: ConnectionState) -> MediaConnectionState {
        switch state {
        case .disconnected:  return .disconnected
        case .connecting:    return .connecting
        case .reconnecting:  return .reconnecting
        case .connected:     return .connected
        case .disconnecting: return .disconnected
        @unknown default:    return .disconnected
        }
    }
}
