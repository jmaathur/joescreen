import XCTest
@testable import JoeScreenKit

final class ParticipantMediaReducerTests: XCTestCase {

    private let a = ParticipantID()
    private let b = ParticipantID()

    func testUpsertRecordsInitialState() {
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "Ada", micLive: true, cameraOn: false))
        XCTAssertEqual(r.states[a], ParticipantMediaState(displayName: "Ada", isSpeaking: false,
                                                          micLive: true, cameraOn: false))
    }

    func testMicMuteThenUnmute() {
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "Ada", micLive: true, cameraOn: true))
        // Mute (isMuted true → micLive false).
        r.reduce(.micLive(id: a, false))
        XCTAssertFalse(r.states[a]!.micLive)
        XCTAssertTrue(r.states[a]!.cameraOn) // camera untouched
        // Unmute.
        r.reduce(.micLive(id: a, true))
        XCTAssertTrue(r.states[a]!.micLive)
    }

    func testCameraOffKeepsEntry_NotFrozenViaSubscription() {
        // The semantic trap: camera-off is a MUTE, not an unpublish — the entry stays, cameraOn flips
        // false (the tile shows an avatar, not a frozen frame). The reducer models exactly that.
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "Ada", micLive: true, cameraOn: true))
        r.reduce(.cameraOn(id: a, false))
        XCTAssertNotNil(r.states[a])          // still present
        XCTAssertFalse(r.states[a]!.cameraOn) // → avatar, not frozen video
    }

    func testSpeakingSetTogglesOnlyMembers() {
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "A", micLive: true, cameraOn: false))
        r.reduce(.upsert(id: b, displayName: "B", micLive: true, cameraOn: false))
        r.reduce(.speakingSet([a]))
        XCTAssertTrue(r.states[a]!.isSpeaking)
        XCTAssertFalse(r.states[b]!.isSpeaking)
        // Switch speaker.
        r.reduce(.speakingSet([b]))
        XCTAssertFalse(r.states[a]!.isSpeaking)
        XCTAssertTrue(r.states[b]!.isSpeaking)
        // Silence.
        r.reduce(.speakingSet([]))
        XCTAssertFalse(r.states[a]!.isSpeaking)
        XCTAssertFalse(r.states[b]!.isSpeaking)
    }

    func testNameChangedUpdatesInPlace() {
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: nil, micLive: false, cameraOn: false))
        r.reduce(.nameChanged(id: a, displayName: "Renamed"))
        XCTAssertEqual(r.states[a]!.displayName, "Renamed")
        // Other fields preserved.
        r.reduce(.micLive(id: a, true))
        r.reduce(.nameChanged(id: a, displayName: "Again"))
        XCTAssertTrue(r.states[a]!.micLive)
        XCTAssertEqual(r.states[a]!.displayName, "Again")
    }

    func testLeftRemovesEntry() {
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "A", micLive: true, cameraOn: true))
        r.reduce(.left(id: a))
        XCTAssertNil(r.states[a])
    }

    func testSeedReplacesWholeMap_lateJoin() {
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "stale", micLive: true, cameraOn: true))
        // A late-join seed derived from room.remoteParticipants is authoritative for who's present now.
        r.seed([
            b: ParticipantMediaState(displayName: "B", isSpeaking: false, micLive: true, cameraOn: false),
        ])
        XCTAssertNil(r.states[a])        // the stale entry is gone
        XCTAssertEqual(r.states[b]!.displayName, "B")
    }

    func testUpsertPreservesExistingSpeakingFlag() {
        // A re-seed/upsert of a participant we already flagged speaking shouldn't wipe the indicator.
        var r = ParticipantMediaReducer()
        r.reduce(.upsert(id: a, displayName: "A", micLive: true, cameraOn: false))
        r.reduce(.speakingSet([a]))
        XCTAssertTrue(r.states[a]!.isSpeaking)
        r.reduce(.upsert(id: a, displayName: "A", micLive: false, cameraOn: true))
        XCTAssertTrue(r.states[a]!.isSpeaking) // preserved across the upsert
        XCTAssertTrue(r.states[a]!.cameraOn)
    }

    func testMuteEventForUnknownParticipantCreatesMinimalEntry() {
        // Defensive: a mute event arriving before the upsert still records something usable.
        var r = ParticipantMediaReducer()
        r.reduce(.cameraOn(id: a, true))
        XCTAssertEqual(r.states[a]!.cameraOn, true)
        XCTAssertNil(r.states[a]!.displayName)
    }
}
