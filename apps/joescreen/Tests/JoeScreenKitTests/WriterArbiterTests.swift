import XCTest
@testable import JoeScreenKit

final class WriterArbiterTests: XCTestCase {
    private let a = ParticipantID()
    private let b = ParticipantID()

    func testTakeWhenFreeSucceeds() {
        var w = WriterArbiter()
        XCTAssertTrue(w.take(a))
        XCTAssertEqual(w.writer, a)
        XCTAssertTrue(w.canWrite(a))
        XCTAssertFalse(w.canWrite(b))
    }

    func testTakeWhenHeldByAnotherFails_noPreemption() {
        var w = WriterArbiter()
        w.take(a)
        XCTAssertFalse(w.take(b))
        XCTAssertEqual(w.writer, a) // unchanged
    }

    func testReAcquireByHolderIsNoOpSuccess() {
        var w = WriterArbiter()
        w.take(a)
        XCTAssertTrue(w.take(a))
        XCTAssertEqual(w.writer, a)
    }

    func testReleaseFreesThenNextTakes_handoff() {
        var w = WriterArbiter()
        w.take(a)
        w.release(a)
        XCTAssertNil(w.writer)
        XCTAssertTrue(w.take(b)) // atomic hand-off = release then take
        XCTAssertEqual(w.writer, b)
    }

    func testReleaseByNonHolderIsNoOp() {
        var w = WriterArbiter()
        w.take(a)
        w.release(b) // b doesn't hold it
        XCTAssertEqual(w.writer, a)
    }

    func testWriterDisconnectClearsTokenOnlyForHolder() {
        var w = WriterArbiter()
        w.take(a)
        w.writerDisconnected(b) // not the writer → no change
        XCTAssertEqual(w.writer, a)
        w.writerDisconnected(a) // the writer left → freed
        XCTAssertNil(w.writer)
    }

    func testCanWriteIsHostGate() {
        // The host only forwards PTY input from the participant who actually holds the token.
        var w = WriterArbiter(writer: a)
        XCTAssertTrue(w.canWrite(a))
        XCTAssertFalse(w.canWrite(b))
        w.release(a)
        XCTAssertFalse(w.canWrite(a)) // nobody holds it now
    }
}
