import Foundation

/// Co-located-speaker dominance gate (echo/crosstalk mitigation for same-room participants).
///
/// Two people in one physical room on separate Macs hear each other twice: once acoustically and
/// once through each other's mics — a doubled, slightly-delayed "reverberant" voice, plus cross-room
/// echo for everyone else. True cross-device AEC (using a remote participant's stream as the echo
/// reference for the local mic) is NOT available from the client SDK's primitives, so the pragmatic
/// industry-standard mitigation is a dominance gate: when a participant the user has MARKED as
/// co-located is clearly the dominant speaker, the local mic yields (is muted by the caller); when
/// the peer goes quiet — or the local talker clearly takes over — the mic is released.
///
/// Pure logic: the platform feeds it speaking flags/levels + timestamps; it emits one Bool
/// (`isYielding` = the caller should mute the local mic). No I/O, no timers, dependency-free.
/// Hysteresis everywhere (hold-to-yield, silence-to-release, retake margin) so it never flaps.
public struct CoLocatedAudioGate: Sendable {

    /// Tunable constants, with the reasoning inline. Defaults are the tuned values; tests inject
    /// their own to compress time.
    public struct Tuning: Sendable {
        /// A sample counts as speech when `isSpeaking` OR `level > speechLevelFloor`. LiveKit's
        /// `audioLevel` is a roughly 0…1 RMS-ish value; the floor guards against room tone when the
        /// SDK's `isSpeaking` flag flickers.
        public var speechLevelFloor: Float
        /// How long some co-located peer must CONTINUOUSLY dominate before the gate yields
        /// (seconds). ~400 ms covers a sentence's first syllables without yielding to coughs,
        /// keyboard clicks, or one-word interjections.
        public var dominanceHoldSeconds: TimeInterval
        /// A co-located peer "dominates" only when its level exceeds the local level by this
        /// factor. Ties and near-ties favor the local talker (no yield). 2× matches the geometry of
        /// two nearby Macs: the talker's own mic is several times closer to their mouth.
        public var dominanceMargin: Float
        /// How long ALL co-located peers must be quiet before a yield releases (seconds). ~1.5 s
        /// spans natural sentence pauses so the mic doesn't chatter mid-utterance.
        public var releaseSilenceSeconds: TimeInterval
        /// While yielded, local speech "clearly dominates" (and starts the retake clock) only when
        /// the local level exceeds the loudest co-located peer by this factor — a higher bar than
        /// dominance so the handoff back is deliberate.
        public var retakeMargin: Float
        /// How long local speech must continuously dominate while yielded before the gate releases
        /// early (seconds). Short (the local talker is asserting the floor) but non-zero so a
        /// single transient doesn't flap the gate.
        public var retakeHoldSeconds: TimeInterval

        public init(speechLevelFloor: Float = 0.01,
                    dominanceHoldSeconds: TimeInterval = 0.4,
                    dominanceMargin: Float = 2.0,
                    releaseSilenceSeconds: TimeInterval = 1.5,
                    retakeMargin: Float = 3.0,
                    retakeHoldSeconds: TimeInterval = 0.25) {
            self.speechLevelFloor = speechLevelFloor
            self.dominanceHoldSeconds = dominanceHoldSeconds
            self.dominanceMargin = dominanceMargin
            self.releaseSilenceSeconds = releaseSilenceSeconds
            self.retakeMargin = retakeMargin
            self.retakeHoldSeconds = retakeHoldSeconds
        }
    }

    /// One remote participant's audio activity at a moment in time.
    public struct RemoteAudioSample: Sendable, Equatable {
        public let participantID: ParticipantID
        public var isSpeaking: Bool
        public var level: Float
        public init(participantID: ParticipantID, isSpeaking: Bool, level: Float) {
            self.participantID = participantID
            self.isSpeaking = isSpeaking
            self.level = level
        }
    }

    private let tuning: Tuning

    /// The gate's output: true = the caller should mute the local mic publication.
    public private(set) var isYielding: Bool = false

    /// Continuous co-located dominance started at this timestamp (nil = nobody dominating now).
    private var dominanceStart: TimeInterval?
    /// Last timestamp at which ANY co-located peer was speaking (drives the release-silence clock).
    private var lastCoLocatedSpeechAt: TimeInterval?
    /// While yielded: continuous local dominance started at this timestamp (drives the retake clock).
    private var retakeStart: TimeInterval?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Feed one sample set. Callers poll this (~10 Hz is plenty). Returns the current output.
    ///
    /// - Parameters:
    ///   - localIsSpeaking / localLevel: the LOCAL participant's speaking flag and level.
    ///   - remotes: speaking flags/levels for every remote participant (co-located or not — the
    ///     gate filters by `coLocated`; participants outside that set NEVER trigger a yield).
    ///   - coLocated: the user-marked set of co-located participant IDs.
    ///   - now: a monotonic timestamp in seconds (e.g. `ProcessInfo.systemUptime`).
    @discardableResult
    public mutating func evaluate(localIsSpeaking: Bool,
                                  localLevel: Float,
                                  remotes: [RemoteAudioSample],
                                  coLocated: Set<ParticipantID>,
                                  now: TimeInterval) -> Bool {
        // Unmarking everyone releases immediately — never leave the mic stuck muted.
        guard !coLocated.isEmpty else {
            release()
            return isYielding
        }

        let coLocatedSamples = remotes.filter { coLocated.contains($0.participantID) }
        let loudestPeer = coLocatedSamples
            .filter { isSpeech($0) }
            .max { $0.level < $1.level }

        if loudestPeer != nil { lastCoLocatedSpeechAt = now }

        if isYielding {
            evaluateRelease(loudestPeer: loudestPeer,
                            localIsSpeaking: localIsSpeaking,
                            localLevel: localLevel,
                            now: now)
        } else {
            evaluateYield(loudestPeer: loudestPeer, localLevel: localLevel, now: now)
        }
        return isYielding
    }

    /// Clear all state (e.g. the user manually toggled the mic, or the call ended).
    public mutating func release() {
        isYielding = false
        dominanceStart = nil
        retakeStart = nil
        // Keep lastCoLocatedSpeechAt: speech that just happened still counts as recent.
    }

    // MARK: - Internals

    private func isSpeech(_ sample: RemoteAudioSample) -> Bool {
        sample.isSpeaking || sample.level > tuning.speechLevelFloor
    }

    /// Not yet yielding: yield when some co-located peer dominates continuously for the hold time.
    private mutating func evaluateYield(loudestPeer: RemoteAudioSample?,
                                        localLevel: Float,
                                        now: TimeInterval) {
        guard let peer = loudestPeer,
              peer.level > localLevel * tuning.dominanceMargin else {
            dominanceStart = nil // dominance broken (or tie) — the hold clock restarts
            return
        }
        let start = dominanceStart ?? now
        dominanceStart = start
        if now - start >= tuning.dominanceHoldSeconds {
            isYielding = true
            retakeStart = nil
        }
    }

    /// Yielding: release on peer silence (release-silence clock) or local takeover (retake clock).
    private mutating func evaluateRelease(loudestPeer: RemoteAudioSample?,
                                          localIsSpeaking: Bool,
                                          localLevel: Float,
                                          now: TimeInterval) {
        // Peer quiet long enough → release. If no co-located speech has EVER been observed this
        // can't fire, but a yield always records speech first, so the timestamp exists.
        if let lastSpeech = lastCoLocatedSpeechAt,
           now - lastSpeech >= tuning.releaseSilenceSeconds {
            release()
            return
        }

        // Local speech clearly dominates sustainedly → release early. (When the caller mutes the
        // mic on yield the local level may read ~0, in which case this path simply never fires and
        // the silence clock above is the release — that's fine.)
        let localDominates = (localIsSpeaking || localLevel > tuning.speechLevelFloor)
            && localLevel > (loudestPeer?.level ?? 0) * tuning.retakeMargin
        if localDominates {
            let start = retakeStart ?? now
            retakeStart = start
            if now - start >= tuning.retakeHoldSeconds {
                release()
            }
        } else {
            retakeStart = nil
        }
    }
}
