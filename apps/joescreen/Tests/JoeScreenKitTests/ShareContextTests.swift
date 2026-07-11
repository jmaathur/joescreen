import XCTest
@testable import JoeScreenKit

final class ShareContextTests: XCTestCase {

    func testEmptyContextIsVP9ButNoShares() {
        // Zero shares → structural codec is H.264 (VP9 requires EXACTLY one window).
        let c = ShareContext()
        XCTAssertEqual(c.totalShareCount, 0)
        XCTAssertFalse(c.wholeDisplay)
        XCTAssertEqual(c.structuralCodec, .h264)
    }

    func testSingleWindowIsVP9() {
        let c = ShareContext(windowShareCount: 1)
        XCTAssertEqual(c.structuralCodec, .vp9)
        XCTAssertFalse(c.wholeDisplay)
    }

    func testTwoWindowsForceH264() {
        XCTAssertEqual(ShareContext(windowShareCount: 2).structuralCodec, .h264)
    }

    func testAnyDisplayForcesH264() {
        // Even a single display share is H.264 (D5).
        XCTAssertEqual(ShareContext(displayShareCount: 1).structuralCodec, .h264)
        // Window + display → H.264.
        XCTAssertEqual(ShareContext(windowShareCount: 1, displayShareCount: 1).structuralCodec, .h264)
    }

    // MARK: - including-the-pending-share (the ordering fix)

    func testAddingWindowFromEmptyStaysVP9() {
        // The FIRST window: context BEFORE=empty (H.264), context WITH-pending=1 window (VP9). The fix
        // is that we compute publish options from the WITH-pending context, so the track is VP9.
        let pending = ShareContext().adding(.window)
        XCTAssertEqual(pending.structuralCodec, .vp9)
    }

    func testAddingSecondWindowFlipsToH264() {
        let base = ShareContext(windowShareCount: 1) // VP9
        let pending = base.adding(.window)           // 2 windows → H.264
        XCTAssertEqual(base.structuralCodec, .vp9)
        XCTAssertEqual(pending.structuralCodec, .h264)
        XCTAssertTrue(base.structuralCodecChanged(to: pending)) // renegotiation needed
    }

    func testAddingDisplayToSingleWindowFlipsToH264() {
        let base = ShareContext(windowShareCount: 1) // VP9
        let pending = base.adding(.display)          // window + display → H.264
        XCTAssertTrue(base.structuralCodecChanged(to: pending))
        XCTAssertEqual(pending.structuralCodec, .h264)
    }

    func testRemovingBackToSingleWindowReturnsVP9Structurally() {
        // Note: the LIVE CodecSelector has one-way hysteresis (no auto-return within a session), but
        // the STRUCTURAL context math is symmetric — 2→1 windows is structurally VP9 again.
        let two = ShareContext(windowShareCount: 2)  // H.264
        let one = two.removing(.window)              // 1 window → VP9 structurally
        XCTAssertEqual(one.structuralCodec, .vp9)
    }

    func testRemovingClampsAtZero() {
        let c = ShareContext(windowShareCount: 0).removing(.window)
        XCTAssertEqual(c.windowShareCount, 0)
        XCTAssertEqual(c.totalShareCount, 0)
    }

    func testStructuralCodecUnchangedForSameKindStaysH264() {
        // 2 → 3 windows: both H.264, no structural flip → no renegotiation.
        let three = ShareContext(windowShareCount: 3)
        let two = ShareContext(windowShareCount: 2)
        XCTAssertFalse(two.structuralCodecChanged(to: three))
    }
}
