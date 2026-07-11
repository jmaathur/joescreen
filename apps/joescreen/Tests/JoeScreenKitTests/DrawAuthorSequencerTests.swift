import XCTest
@testable import JoeScreenKit

final class DrawAuthorSequencerTests: XCTestCase {
    func testStartsAtOneAndAdvancesMonotonically() {
        var s = DrawAuthorSequencer()
        XCTAssertEqual(s.advance(), 1)
        XCTAssertEqual(s.advance(), 2)
        XCTAssertEqual(s.advance(), 3)
        XCTAssertEqual(s.peek, 4)
    }

    func testCustomStartClampedToOne() {
        var s = DrawAuthorSequencer(start: 0)
        XCTAssertEqual(s.advance(), 1) // 0 clamped to 1
        var s2 = DrawAuthorSequencer(start: 10)
        XCTAssertEqual(s2.advance(), 10)
    }

    func testSequenceAcceptedInOrderByDrawModelRejectsReplay() {
        // The reason the sequencer exists: monotonic seqs are accepted; a replayed old one is dropped.
        var seq = DrawAuthorSequencer()
        var model = DrawModel()
        let author = ParticipantID(); let w = WindowID()
        func op(_ s: UInt64) -> DrawOp {
            DrawOp(authorID: author, authorSeq: s, windowID: w, points: [.init(x: 0, y: 0), .init(x: 1, y: 1)],
                   color: .init(r: 1, g: 0, b: 0, a: 1), width: 2)
        }
        XCTAssertEqual(model.apply(op(seq.advance())), .applied) // 1
        XCTAssertEqual(model.apply(op(seq.advance())), .applied) // 2
        // A replay of seq 1 (e.g. after a reconnect) is rejected, not duplicated.
        XCTAssertEqual(model.apply(op(1)), .rejectedStaleSequence(lastApplied: 2))
        XCTAssertEqual(model.strokeCount(in: w), 2)
    }
}
