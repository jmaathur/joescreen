import XCTest
@testable import JoeScreenKit

final class CoLocatedAudioGateTests: XCTestCase {

    private let henry = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let grace = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func sample(_ id: UUID, _ speaking: Bool, _ level: Float) -> CoLocatedAudioGate.RemoteAudioSample {
        .init(participantID: id, isSpeaking: speaking, level: level)
    }

    func testCoLocatedDominanceYieldsAfterHold() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        // Henry (co-located) talks loudly; the local mic hears him much quieter.
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0),
                       "dominance must persist before yielding")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.39),
                       "yield fires only after the full hold (400 ms)")
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                    remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.4),
                      "sustained co-located dominance yields the local mic")
        XCTAssertTrue(gate.isYielding, "isYielding mirrors the returned output")
    }

    func testDominanceMustBeContinuous() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        // 300 ms of dominance, a 100 ms break, then another 300 ms: must NOT yield (hold restarts).
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0),
                       "initial dominance starts the clock")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, false, 0)], coLocated: set, now: 0.3),
                       "a break in dominance resets the hold clock")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.4),
                       "clock restarts at the new dominance onset")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.79),
                       "interrupted dominance must not accumulate — no flapping")
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                    remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.8),
                      "only continuous dominance yields")
    }

    func testNonCoLocatedPeerNeverGates() {
        var gate = CoLocatedAudioGate()
        // Grace is loud and dominant but NOT marked co-located; henry (marked) stays quiet.
        let set: Set<ParticipantID> = [henry]
        for t in stride(from: 0.0, through: 10.0, by: 0.1) {
            XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.05,
                                         remotes: [sample(grace, true, 0.9),
                                                   sample(henry, false, 0)],
                                         coLocated: set, now: t),
                           "non-co-located participants must never trigger the gate (t=\(t))")
        }
    }

    func testReleaseAfterPeerSilence() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                          remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                    remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.4),
                      "yielded by sustained dominance")
        // Henry's last observed speech is at t=1.0; he goes quiet after that.
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                          remotes: [sample(henry, true, 0.5)], coLocated: set, now: 1.0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                                    remotes: [sample(henry, false, 0)], coLocated: set, now: 2.49),
                      "still yielding before the silence window elapses")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                                     remotes: [sample(henry, false, 0)], coLocated: set, now: 2.5),
                       "releases after 1.5 s of co-located quiet")
    }

    func testPeerSpeechResetsSilenceClock() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                          remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                    remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.4),
                      "yielded")
        // Quiet for 1.2 s (not enough), one syllable at t=1.6, quiet again.
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                                    remotes: [sample(henry, false, 0)], coLocated: set, now: 1.6),
                      "short pauses keep the gate yielded")
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                          remotes: [sample(henry, true, 0.5)], coLocated: set, now: 1.6)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                                    remotes: [sample(henry, false, 0)], coLocated: set, now: 3.0),
                      "silence clock restarted by the interjection (1.4 s < 1.5 s)")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                                     remotes: [sample(henry, false, 0)], coLocated: set, now: 3.1),
                       "1.5 s after the LAST speech, the gate releases")
    }

    func testTieFavorsLocalTalker() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        // Exactly equal levels: no dominance.
        for t in stride(from: 0.0, through: 3.0, by: 0.5) {
            XCTAssertFalse(gate.evaluate(localIsSpeaking: true, localLevel: 0.4,
                                         remotes: [sample(henry, true, 0.4)], coLocated: set, now: t),
                           "equal levels must not yield — ties favor the local talker")
        }
        // Just under the dominance margin (1.9× < 2.0×): still no yield.
        for t in stride(from: 4.0, through: 7.0, by: 0.5) {
            XCTAssertFalse(gate.evaluate(localIsSpeaking: true, localLevel: 0.4,
                                         remotes: [sample(henry, true, 0.76)], coLocated: set, now: t),
                           "below the dominance margin the gate stays open")
        }
        // Over the margin: yields after the hold.
        _ = gate.evaluate(localIsSpeaking: true, localLevel: 0.4,
                          remotes: [sample(henry, true, 0.9)], coLocated: set, now: 8.0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: true, localLevel: 0.4,
                                    remotes: [sample(henry, true, 0.9)], coLocated: set, now: 8.4),
                      "clear peer dominance (2.25×) yields even while the local user talks")
    }

    func testLocalTakeoverReleasesEarly() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                          remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                    remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.4),
                      "yielded")
        // The local user talks over Henry clearly (0.6 > 0.15 × retakeMargin 3.0).
        XCTAssertTrue(gate.evaluate(localIsSpeaking: true, localLevel: 0.6,
                                    remotes: [sample(henry, true, 0.15)], coLocated: set, now: 1.0),
                      "retake needs the sustained hold too")
        XCTAssertTrue(gate.evaluate(localIsSpeaking: true, localLevel: 0.6,
                                    remotes: [sample(henry, true, 0.15)], coLocated: set, now: 1.24),
                      "still yielded just before the retake hold elapses")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: true, localLevel: 0.6,
                                     remotes: [sample(henry, true, 0.15)], coLocated: set, now: 1.25),
                       "sustained local dominance releases the gate early")
    }

    func testUnmarkingAllReleasesImmediately() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                          remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                    remotes: [sample(henry, true, 0.5)], coLocated: set, now: 0.4),
                      "yielded")
        XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.1,
                                     remotes: [sample(henry, true, 0.5)], coLocated: [], now: 0.5),
                       "an empty co-located set releases immediately — never leave the mic stuck")
    }

    func testSpeakingFlagCountsAsSpeechAtLowLevel() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        // isSpeaking=true with a small (but still 2×-dominant) level must still drive the gate.
        _ = gate.evaluate(localIsSpeaking: false, localLevel: 0.002,
                          remotes: [sample(henry, true, 0.005)], coLocated: set, now: 0)
        XCTAssertTrue(gate.evaluate(localIsSpeaking: false, localLevel: 0.002,
                                    remotes: [sample(henry, true, 0.005)], coLocated: set, now: 0.4),
                      "the SDK's isSpeaking flag alone (level below the floor) still counts as speech")
    }

    func testQuietCoLocatedPeerDoesNotYield() {
        var gate = CoLocatedAudioGate()
        let set: Set<ParticipantID> = [henry]
        for t in stride(from: 0.0, through: 5.0, by: 0.5) {
            XCTAssertFalse(gate.evaluate(localIsSpeaking: false, localLevel: 0.0,
                                         remotes: [sample(henry, false, 0.005)],
                                         coLocated: set, now: t),
                           "a co-located peer below the speech floor never yields the mic")
        }
    }
}
