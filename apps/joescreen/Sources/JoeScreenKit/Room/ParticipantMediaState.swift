import Foundation

/// A framework-free snapshot of one participant's live media presence for the tile strip (M10):
/// their display name, whether they're currently speaking, and whether their mic / camera are LIVE.
///
/// **Semantic trap (verified):** LiveKit `setCamera(false)`/`setMicrophone(false)` **mute** the
/// publication rather than unpublishing it — a muted camera track stays subscribed (and would render
/// a frozen last frame). So `micLive`/`cameraOn` here MUST be fed from `publication.isMuted`, never
/// from track un/subscription. The reducer just folds those booleans; the transport is responsible
/// for reading the correct source.
public struct ParticipantMediaState: Sendable, Equatable {
    public var displayName: String?
    public var isSpeaking: Bool
    /// Mic is published AND unmuted.
    public var micLive: Bool
    /// Camera is published AND unmuted (a renderable, non-frozen camera).
    public var cameraOn: Bool

    public init(displayName: String? = nil, isSpeaking: Bool = false,
                micLive: Bool = false, cameraOn: Bool = false) {
        self.displayName = displayName
        self.isSpeaking = isSpeaking
        self.micLive = micLive
        self.cameraOn = cameraOn
    }
}

/// A pure reducer that folds media-presence events into `[ParticipantID: ParticipantMediaState]`.
/// The transport maps LiveKit delegate callbacks to these events and pushes the resulting snapshot;
/// keeping the fold pure makes the mute→unmute + late-join-seeding logic unit-testable without a
/// live SFU. Idempotent by construction — the same event stream always yields the same map.
public struct ParticipantMediaReducer: Sendable, Equatable {

    public private(set) var states: [ParticipantID: ParticipantMediaState] = [:]

    public init() {}

    public enum Event: Sendable, Equatable {
        /// A participant appeared (or late-join seeding). Carries the full initial snapshot fields.
        case upsert(id: ParticipantID, displayName: String?, micLive: Bool, cameraOn: Bool)
        /// A participant left — drop them entirely.
        case left(id: ParticipantID)
        /// The display name changed (didUpdateName).
        case nameChanged(id: ParticipantID, displayName: String?)
        /// The full set of currently-speaking participants (didUpdateSpeakingParticipants). Everyone
        /// not in the set is set non-speaking.
        case speakingSet(Set<ParticipantID>)
        /// Mic mute flipped (from publication.isMuted). `micLive == !muted && published`.
        case micLive(id: ParticipantID, Bool)
        /// Camera mute flipped (from publication.isMuted). `cameraOn == !muted && published`.
        case cameraOn(id: ParticipantID, Bool)
    }

    /// Fold one event; returns the updated snapshot map for convenience.
    @discardableResult
    public mutating func reduce(_ event: Event) -> [ParticipantID: ParticipantMediaState] {
        switch event {
        case let .upsert(id, name, micLive, cameraOn):
            // Preserve an existing speaking flag if we already knew about them (a re-seed shouldn't
            // wipe a live speaking indicator); default false for a brand-new participant.
            let speaking = states[id]?.isSpeaking ?? false
            states[id] = ParticipantMediaState(displayName: name, isSpeaking: speaking,
                                               micLive: micLive, cameraOn: cameraOn)
        case let .left(id):
            states[id] = nil
        case let .nameChanged(id, name):
            if var s = states[id] { s.displayName = name; states[id] = s }
            else { states[id] = ParticipantMediaState(displayName: name) }
        case let .speakingSet(speakers):
            for (id, var s) in states {
                let speaking = speakers.contains(id)
                if s.isSpeaking != speaking { s.isSpeaking = speaking; states[id] = s }
            }
            // A speaker we don't have a record for yet gets a minimal entry (defensive).
            for id in speakers where states[id] == nil {
                states[id] = ParticipantMediaState(isSpeaking: true)
            }
        case let .micLive(id, live):
            if var s = states[id] { s.micLive = live; states[id] = s }
            else { states[id] = ParticipantMediaState(micLive: live) }
        case let .cameraOn(id, on):
            if var s = states[id] { s.cameraOn = on; states[id] = s }
            else { states[id] = ParticipantMediaState(cameraOn: on) }
        }
        return states
    }

    /// Replace the whole map from a fresh seed (late-join derivation from room.remoteParticipants).
    /// Preserves nothing — the seed is authoritative for who is present right now.
    public mutating func seed(_ snapshot: [ParticipantID: ParticipantMediaState]) {
        states = snapshot
    }
}
