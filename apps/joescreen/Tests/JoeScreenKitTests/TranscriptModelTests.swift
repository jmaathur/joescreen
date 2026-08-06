import XCTest
@testable import JoeScreenKit

final class TranscriptModelTests: XCTestCase {

    private let noteA = UUID()
    private let noteB = UUID()
    private let speakerA = UUID()
    private let speakerB = UUID()

    private func segment(_ id: UUID, note: UUID? = nil, speaker: UUID? = nil,
                         text: String, at t: TimeInterval, final: Bool = true) -> TranscriptSegment {
        TranscriptSegment(segmentID: id, noteID: note ?? noteA, speakerID: speaker ?? speakerA,
                          text: text, startTime: t, isFinal: final)
    }

    private func start(_ note: UUID, at t: TimeInterval, title: String = "") -> RecordingNoteEvent {
        RecordingNoteEvent(noteID: note, action: .start, startedAt: t, title: title)
    }

    private func stop(_ note: UUID, startedAt: TimeInterval, at t: TimeInterval) -> RecordingNoteEvent {
        RecordingNoteEvent(noteID: note, action: .stop, startedAt: startedAt, endedAt: t)
    }

    // MARK: - Notes

    func testStartThenStopFinalizesNoteIdempotently() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 100))
        XCTAssertEqual(m.notes.count, 1)
        XCTAssertTrue(m.notes[0].isOpen)
        XCTAssertEqual(m.currentNote?.noteID, noteA)

        m.apply(stop(noteA, startedAt: 100, at: 200))
        XCTAssertEqual(m.notes[0].endedAt, 200)
        XCTAssertFalse(m.notes[0].isOpen)
        XCTAssertNil(m.currentNote)

        // Re-applying the same events is a no-op (idempotent).
        m.apply(stop(noteA, startedAt: 100, at: 200))
        m.apply(start(noteA, at: 100))
        XCTAssertEqual(m.notes.count, 1)
        XCTAssertEqual(m.notes[0].endedAt, 200, "a duplicate start must not reopen a stopped note")
    }

    func testNoteEventsAreLastWriterWinsByEventTime() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 100))
        m.apply(stop(noteA, startedAt: 100, at: 300))
        // A stale stop (older event time) is dropped.
        m.apply(stop(noteA, startedAt: 100, at: 200))
        XCTAssertEqual(m.notes[0].endedAt, 300)
        // A newer stop wins.
        m.apply(stop(noteA, startedAt: 100, at: 400))
        XCTAssertEqual(m.notes[0].endedAt, 400)
        // A start whose event time predates the applied stop is dropped (no reopen).
        m.apply(start(noteA, at: 100))
        XCTAssertFalse(m.notes[0].isOpen)
    }

    func testNotesSortByStartTimeAndCurrentIsLatestOpen() {
        var m = TranscriptModel()
        m.apply(start(noteB, at: 300))
        m.apply(start(noteA, at: 100))
        XCTAssertEqual(m.notes.map(\.startedAt), [100, 300])
        // Both open (race) → the later-started one is current.
        XCTAssertEqual(m.currentNote?.noteID, noteB)
        m.apply(stop(noteB, startedAt: 300, at: 400))
        // With B closed, A is current again.
        XCTAssertEqual(m.currentNote?.noteID, noteA)
    }

    // MARK: - Segments

    func testFinalsMergeOrderedByStartTime() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 0))
        let s1 = segment(UUID(), text: "third", at: 30)
        let s2 = segment(UUID(), text: "first", at: 10)
        let s3 = segment(UUID(), text: "second", at: 20)
        for s in [s1, s2, s3] { m.apply(s) }
        XCTAssertEqual(m.segments(for: noteA).map(\.text), ["first", "second", "third"])
    }

    func testDuplicateFinalDeduplicatesBySegmentID() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 0))
        let id = UUID()
        m.apply(segment(id, text: "hello", at: 5))
        m.apply(segment(id, text: "hello", at: 5))
        XCTAssertEqual(m.segments(for: noteA).count, 1)
    }

    func testFinalOverwritesPartialAndPartialNeverOverwritesFinal() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 0))
        let id = UUID()
        m.apply(segment(id, text: "hel", at: 5, final: false))
        m.apply(segment(id, text: "hello", at: 5, final: false))
        XCTAssertEqual(m.liveSegments.map(\.text), ["hello"], "latest partial wins")
        XCTAssertTrue(m.segments(for: noteA).isEmpty, "partials are not recorded into the note")

        m.apply(segment(id, text: "hello world", at: 5, final: true))
        XCTAssertEqual(m.segments(for: noteA).map(\.text), ["hello world"])
        XCTAssertTrue(m.liveSegments.isEmpty, "the final retires its partial")

        m.apply(segment(id, text: "stale partial", at: 5, final: false))
        XCTAssertTrue(m.liveSegments.isEmpty, "a late partial must not resurrect a final")
        XCTAssertEqual(m.segments(for: noteA).map(\.text), ["hello world"])
    }

    func testMultiSpeakerInterleaveOrdersAcrossSpeakers() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 0))
        m.apply(segment(UUID(), speaker: speakerA, text: "A1", at: 10))
        m.apply(segment(UUID(), speaker: speakerB, text: "B1", at: 12))
        m.apply(segment(UUID(), speaker: speakerA, text: "A2", at: 14))
        m.apply(segment(UUID(), speaker: speakerB, text: "B2", at: 11))
        let got = m.segments(for: noteA)
        XCTAssertEqual(got.map(\.text), ["A1", "B2", "B1", "A2"])
        XCTAssertEqual(Set(got.map(\.speakerID)), [speakerA, speakerB])
    }

    func testSegmentForUnknownNoteMaterializesImplicitNoteFilledInByStart() {
        var m = TranscriptModel()
        let id = UUID()
        m.apply(segment(id, note: noteA, text: "early words", at: 50))
        XCTAssertEqual(m.notes.count, 1, "an implicit note keeps the segment from being lost")
        XCTAssertEqual(m.segments(for: noteA).map(\.text), ["early words"])

        m.apply(start(noteA, at: 40, title: "Standup"))
        XCTAssertEqual(m.notes.count, 1, "the start event fills in the same note, not a second one")
        XCTAssertEqual(m.notes[0].startedAt, 40)
        XCTAssertEqual(m.notes[0].title, "Standup")
        XCTAssertEqual(m.segments(for: noteA).count, 1)
    }

    // MARK: - Titles

    func testAutoTitleFromFirstWordsAndTimestampFallback() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 100))
        XCTAssertEqual(m.displayTitle(for: noteA),
                       TranscriptModel.timestampTitle(startedAt: 100),
                       "no words yet → timestamp fallback")
        m.apply(segment(UUID(), text: "let us discuss the roadmap for the next quarter today", at: 101))
        XCTAssertEqual(m.displayTitle(for: noteA), "let us discuss the roadmap for the next…")
    }

    func testExplicitEventTitleWinsAndIsNotClobberedByAutoTitle() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 100, title: "Planning"))
        m.apply(segment(UUID(), text: "some spoken words", at: 101))
        XCTAssertEqual(m.displayTitle(for: noteA), "Planning")
    }

    // MARK: - Live partials

    func testLiveSegmentsOrderedAcrossSpeakers() {
        var m = TranscriptModel()
        m.apply(start(noteA, at: 0))
        m.apply(segment(UUID(), speaker: speakerB, text: "B live", at: 20, final: false))
        m.apply(segment(UUID(), speaker: speakerA, text: "A live", at: 10, final: false))
        XCTAssertEqual(m.liveSegments.map(\.text), ["A live", "B live"])
    }
}
