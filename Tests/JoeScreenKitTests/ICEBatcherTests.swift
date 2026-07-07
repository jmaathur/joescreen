import XCTest
@testable import JoeScreenKit

final class ICEBatcherTests: XCTestCase {

    private func cand(_ s: String) -> ICECandidate {
        ICECandidate(sdpMid: "0", sdpMLineIndex: 0, candidate: s)
    }

    func testMultipleCandidatesCoalesceIntoOneBatch() {
        var b = ICECandidateBatcher(debounceSeconds: 0.15)
        // Three candidates within the debounce window → no immediate emit.
        XCTAssertNil(b.add(cand("a"), now: 0.00))
        XCTAssertNil(b.add(cand("b"), now: 0.05))
        XCTAssertNil(b.add(cand("c"), now: 0.10))
        // After the window elapses, ONE batch of all three.
        let batch = b.flushIfDue(now: 0.20)
        XCTAssertEqual(batch?.candidates.count, 3)
        XCTAssertEqual(batch?.endOfCandidates, false)
    }

    func testNoBatchBeforeDebounce() {
        var b = ICECandidateBatcher(debounceSeconds: 0.15)
        _ = b.add(cand("a"), now: 0)
        XCTAssertNil(b.flushIfDue(now: 0.10), "not due yet")
    }

    func testAddPastDebounceEmitsImmediately() {
        var b = ICECandidateBatcher(debounceSeconds: 0.15)
        _ = b.add(cand("a"), now: 0)
        // A later add whose now is past the window returns the batch on add().
        let batch = b.add(cand("b"), now: 0.20)
        XCTAssertEqual(batch?.candidates.count, 2)
    }

    func testFlushEndForcesBatchWithEndFlag() {
        var b = ICECandidateBatcher(debounceSeconds: 10)
        _ = b.add(cand("a"), now: 0)
        let end = b.flushEnd()
        XCTAssertTrue(end.endOfCandidates)
        XCTAssertEqual(end.candidates.count, 1)
        XCTAssertTrue(b.didFlushEnd)
    }

    func testFlushEndEmptyStillSignalsEnd() {
        var b = ICECandidateBatcher()
        let end = b.flushEnd()
        XCTAssertTrue(end.endOfCandidates)
        XCTAssertEqual(end.candidates.count, 0)
    }

    func testMergeIsIdempotent() {
        var set: [ICECandidate] = []
        let batch = ICEBatch(candidates: [cand("a"), cand("b")], endOfCandidates: false)
        ICECandidateBatcher.merge(into: &set, batch: batch)
        ICECandidateBatcher.merge(into: &set, batch: batch) // duplicate delivery
        XCTAssertEqual(set.count, 2, "re-delivered batch must not duplicate")
    }
}
