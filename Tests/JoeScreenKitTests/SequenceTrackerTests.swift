import XCTest
@testable import JoeScreenKit

final class SequenceTrackerTests: XCTestCase {
    let a = UUID()
    let b = UUID()

    func testFirstMessageAccepted() {
        var t = SequenceTracker()
        XCTAssertEqual(t.offer(sender: a, seq: 100), .accept)
        XCTAssertEqual(t.lastSeq(for: a), 100)
    }

    func testInOrderAccepted() {
        var t = SequenceTracker()
        XCTAssertEqual(t.offer(sender: a, seq: 5), .accept)
        XCTAssertEqual(t.offer(sender: a, seq: 6), .accept)
        XCTAssertEqual(t.offer(sender: a, seq: 7), .accept)
    }

    func testDuplicateDropped() {
        var t = SequenceTracker()
        _ = t.offer(sender: a, seq: 5)
        _ = t.offer(sender: a, seq: 6)
        XCTAssertEqual(t.offer(sender: a, seq: 6), .duplicate)
        XCTAssertEqual(t.offer(sender: a, seq: 4), .duplicate)
    }

    func testGapDetectedAndReported() {
        var t = SequenceTracker()
        _ = t.offer(sender: a, seq: 10)
        // Jump to 14 → 11,12,13 lost.
        XCTAssertEqual(t.offer(sender: a, seq: 14), .gap(missing: 11...13))
        XCTAssertEqual(t.lastSeq(for: a), 14)
        // A late in-gap arrival now reads as duplicate (we moved past it).
        XCTAssertEqual(t.offer(sender: a, seq: 12), .duplicate)
    }

    func testPerSenderIndependence() {
        var t = SequenceTracker()
        _ = t.offer(sender: a, seq: 1)
        _ = t.offer(sender: b, seq: 1000)
        // a's gap does not affect b.
        XCTAssertEqual(t.offer(sender: a, seq: 3), .gap(missing: 2...2))
        XCTAssertEqual(t.offer(sender: b, seq: 1001), .accept)
    }

    func testForgetResetsBaseline() {
        var t = SequenceTracker()
        _ = t.offer(sender: a, seq: 50)
        t.forget(a)
        XCTAssertFalse(t.hasSeen(a))
        // Rejoin re-baselines at any value.
        XCTAssertEqual(t.offer(sender: a, seq: 3), .accept)
    }

    func testGeneratorMonotonic() {
        var g = SequenceGenerator(start: 0)
        XCTAssertEqual(g.take(), 0)
        XCTAssertEqual(g.take(), 1)
        XCTAssertEqual(g.take(), 2)
    }
}
