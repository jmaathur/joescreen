import Foundation

/// Tracks the two authoritative ways a direct call can end:
///
/// - the media room disconnects after having connected; or
/// - every remote participant leaves after at least one remote participant was present.
///
/// `MediaTransport.connectionStates()` intentionally starts with its current value, which is
/// `.disconnected` before the first connection attempt. Remembering that a connection was actually
/// established prevents that seed value from being mistaken for a call ending.
public struct CallEndDetector: Sendable {
    private var latestConnectionState: MediaConnectionState = .disconnected
    private var hasConnected = false
    private var hasSeenRemoteParticipant = false
    private var hasReportedEmptyRoster = false
    private var hasEnded = false

    public init() {}

    /// Reset all history before starting a new call.
    public mutating func reset() {
        latestConnectionState = .disconnected
        hasConnected = false
        hasSeenRemoteParticipant = false
        hasReportedEmptyRoster = false
        hasEnded = false
    }

    /// Returns `true` exactly once when an established media connection becomes disconnected.
    public mutating func observeConnection(_ state: MediaConnectionState) -> Bool {
        guard !hasEnded else { return false }
        latestConnectionState = state
        switch state {
        case .connected:
            hasConnected = true
        case .connecting, .reconnecting:
            // A last-participant grace check can race a brief transport reconnect. If the check
            // cannot confirm the empty roster while connected, allow the authoritative roster
            // seed delivered by the next `.connected` event to report it again.
            hasReportedEmptyRoster = false
        case .disconnected where hasConnected:
            hasEnded = true
            return true
        case .failed where hasConnected:
            hasEnded = true
            return true
        case .disconnected, .failed:
            break
        }
        return false
    }

    /// Returns `true` when the last remote participant leaves an established call, allowing the
    /// caller to start a grace period and confirm against its authoritative roster afterward.
    /// An initially empty room remains joinable: it does not end until a remote participant has
    /// actually appeared and subsequently departed. If a participant returns during the grace
    /// period, a later departure is reported again.
    public mutating func observeParticipants(
        _ participants: Set<ParticipantID>,
        localParticipantID: ParticipantID?
    ) -> Bool {
        guard !hasEnded else { return false }
        var remotes = participants
        if let localParticipantID { remotes.remove(localParticipantID) }
        if !remotes.isEmpty {
            hasSeenRemoteParticipant = true
            hasReportedEmptyRoster = false
            return false
        }
        guard latestConnectionState == .connected,
              hasConnected, hasSeenRemoteParticipant, !hasReportedEmptyRoster else { return false }
        hasReportedEmptyRoster = true
        return true
    }
}
