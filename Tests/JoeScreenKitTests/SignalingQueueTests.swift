import XCTest
@testable import JoeScreenKit

final class SignalingQueueTests: XCTestCase {

    func testOversizeRejectedBeforeMessenger() {
        var q = SignalingSendQueue(config: .init(maxMessageBytes: 100))
        XCTAssertThrowsError(try q.enqueue(Data(count: 200), now: 0)) { err in
            guard case SignalingSendQueue.EnqueueError.tooLarge(200, 100) = err else {
                return XCTFail("expected tooLarge, got \(err)")
            }
        }
    }

    func testBackpressureAtMaxDepth() throws {
        var q = SignalingSendQueue(config: .init(maxMessageBytes: 1000, maxDepth: 2))
        _ = try q.enqueue(Data([1]), now: 0)
        _ = try q.enqueue(Data([2]), now: 0)
        XCTAssertThrowsError(try q.enqueue(Data([3]), now: 0)) { err in
            guard case SignalingSendQueue.EnqueueError.backpressure(2) = err else {
                return XCTFail("expected backpressure, got \(err)")
            }
        }
    }

    func testSuccessRemovesItem() throws {
        var q = SignalingSendQueue()
        let id = try q.enqueue(Data([1]), now: 0)
        XCTAssertEqual(q.depth, 1)
        q.reportSuccess(id)
        XCTAssertTrue(q.isEmpty)
    }

    func testFailureSchedulesRetryWithBackoff() throws {
        var q = SignalingSendQueue(config: .init(baseBackoff: 0.1, maxBackoff: 5, maxAttempts: 8))
        let id = try q.enqueue(Data([1]), now: 0)
        // First failure → retry, not eligible immediately.
        XCTAssertEqual(q.reportFailure(id, now: 0), .throttledRetry)
        XCTAssertNil(q.nextReady(now: 0.05), "still backing off")
        XCTAssertNotNil(q.nextReady(now: 0.11), "eligible after backoff")
    }

    func testExhaustedAttemptsDropPermanently() throws {
        var q = SignalingSendQueue(config: .init(maxAttempts: 2))
        let id = try q.enqueue(Data([1]), now: 0)
        XCTAssertEqual(q.reportFailure(id, now: 0), .throttledRetry) // attempt 1
        XCTAssertEqual(q.reportFailure(id, now: 0), .permanentFailure) // attempt 2 → drop
        XCTAssertTrue(q.isEmpty)
    }

    func testFIFOOrderPreserved() throws {
        var q = SignalingSendQueue()
        _ = try q.enqueue(Data([10]), now: 0)
        _ = try q.enqueue(Data([20]), now: 0)
        XCTAssertEqual(q.nextReady(now: 0)?.payload, Data([10]))
    }

    func testPerPeerHandshakeStagger() throws {
        var q = SignalingSendQueue(config: .init(), peerStaggerSeconds: 0.05)
        _ = try q.enqueue(Data([1]), peerKey: "peerA", now: 0)
        _ = try q.enqueue(Data([2]), peerKey: "peerA", now: 0)
        // The two same-peer items must not both be ready in the same tick.
        let ready = q.nextReady(now: 0)
        XCTAssertEqual(ready?.payload, Data([1]))
        // Second same-peer item is staggered past now.
        let items = (0..<2).compactMap { _ in q.nextReady(now: 0) }
        XCTAssertTrue(items.allSatisfy { $0.payload == Data([1]) }, "second peerA item is gated later")
    }
}
