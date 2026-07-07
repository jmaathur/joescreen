import XCTest
@testable import JoeScreenKit

final class CursorCoalescerTests: XCTestCase {
    let winA = UUID()
    let winB = UUID()
    let sender = UUID()
    let other = UUID()

    private func move(_ win: UUID, _ x: Double, _ t: Double) -> CursorMove {
        CursorMove(windowID: win, point: NormalizedPoint(x: x, y: 0.5), timestamp: t)
    }

    // Outbound: multiple moves for one window coalesce to the latest.
    func testOutboundCoalescesToLatestPerWindow() {
        var c = CursorCoalescer()
        c.offerOutbound(move(winA, 0.1, 1))
        c.offerOutbound(move(winA, 0.2, 2))
        c.offerOutbound(move(winA, 0.3, 3))
        let flushed = c.flushOutbound()
        XCTAssertEqual(flushed.count, 1, "one window → one coalesced move")
        XCTAssertEqual(flushed.first?.point.x, 0.3, "keeps the latest position")
        XCTAssertFalse(c.hasPending)
    }

    // Outbound: separate windows each get one coalesced move.
    func testOutboundKeepsOneMovePerWindow() {
        var c = CursorCoalescer()
        c.offerOutbound(move(winA, 0.1, 1))
        c.offerOutbound(move(winB, 0.9, 1))
        c.offerOutbound(move(winA, 0.5, 2))
        XCTAssertEqual(c.pendingCount, 2)
        let flushed = c.flushOutbound().sorted { $0.point.x < $1.point.x }
        XCTAssertEqual(flushed.count, 2)
        XCTAssertEqual(flushed[0].point.x, 0.5) // winA latest
        XCTAssertEqual(flushed[1].point.x, 0.9) // winB
    }

    // Outbound: an out-of-order (older) local sample doesn't clobber a newer pending one.
    func testOutboundIgnoresOlderSample() {
        var c = CursorCoalescer()
        c.offerOutbound(move(winA, 0.5, 5))
        c.offerOutbound(move(winA, 0.1, 3)) // older timestamp
        XCTAssertEqual(c.flushOutbound().first?.point.x, 0.5, "older sample is ignored")
    }

    // Flush empties the buffer.
    func testFlushEmptiesBuffer() {
        var c = CursorCoalescer()
        c.offerOutbound(move(winA, 0.1, 1))
        _ = c.flushOutbound()
        XCTAssertFalse(c.hasPending)
        XCTAssertTrue(c.flushOutbound().isEmpty)
    }

    // Inbound: newer timestamps accepted, older dropped as stale.
    func testInboundLatestWins() {
        var c = CursorCoalescer()
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winA, 0.1, 10)))
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winA, 0.2, 11)))
        // Reordered older arrival → stale, dropped.
        XCTAssertFalse(c.acceptInbound(sender: sender, move: move(winA, 0.15, 10.5)))
        // Equal timestamp → also dropped (not newer).
        XCTAssertFalse(c.acceptInbound(sender: sender, move: move(winA, 0.9, 11)))
        // Newer → accepted.
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winA, 0.3, 12)))
    }

    // Inbound: per-(sender, window) independence.
    func testInboundPerSenderWindowIndependence() {
        var c = CursorCoalescer()
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winA, 0.1, 100)))
        // Different sender, same window → independent baseline.
        XCTAssertTrue(c.acceptInbound(sender: other, move: move(winA, 0.1, 5)))
        // Same sender, different window → independent baseline.
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winB, 0.1, 5)))
    }

    // Inbound: forget re-baselines a sender.
    func testInboundForgetRebaselines() {
        var c = CursorCoalescer()
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winA, 0.1, 100)))
        c.forgetInbound(sender)
        // After forget, an older timestamp is accepted (baseline reset).
        XCTAssertTrue(c.acceptInbound(sender: sender, move: move(winA, 0.1, 5)))
    }
}
