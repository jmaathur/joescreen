import XCTest
@testable import JoeScreenKit

/// The structural-renegotiation decision table (M11): which live share tracks must republish (flip
/// codec) when the share set changes. The transport republishes exactly the tracks whose published
/// codec no longer matches `context.structuralCodec`; this documents the boundary conditions.
final class RenegotiationDecisionTests: XCTestCase {

    /// Whether adding `kind` to a context flips the structural codec (⇒ live tracks renegotiate).
    private func flips(from: ShareContext, adding kind: ShareKind) -> Bool {
        from.structuralCodecChanged(to: from.adding(kind))
    }
    private func flips(from: ShareContext, removing kind: ShareKind) -> Bool {
        from.structuralCodecChanged(to: from.removing(kind))
    }

    func testFirstWindowNoLiveTracksNoRenegotiation() {
        // Empty → 1 window: nothing live to renegotiate (the new track publishes VP9 directly).
        XCTAssertTrue(flips(from: ShareContext(), adding: .window)) // H.264(empty) → VP9
        // But with zero existing tracks the transport renegotiates 0 (only the new one publishes).
    }

    func testDisplayJoiningSingleWindowFlipsVP9ToH264() {
        // The canonical case: a live VP9 window + a display share joins ⇒ the window renegotiates H.264.
        let base = ShareContext(windowShareCount: 1) // VP9
        XCTAssertTrue(flips(from: base, adding: .display))
        XCTAssertEqual(base.structuralCodec, .vp9)
        XCTAssertEqual(base.adding(.display).structuralCodec, .h264)
    }

    func testSecondWindowFlipsVP9ToH264() {
        let base = ShareContext(windowShareCount: 1)
        XCTAssertTrue(flips(from: base, adding: .window)) // 1→2 windows: VP9 → H.264
    }

    func testThirdWindowNoFlip() {
        // Already H.264 at 2 windows; 2→3 stays H.264 → no renegotiation.
        XCTAssertFalse(flips(from: ShareContext(windowShareCount: 2), adding: .window))
    }

    func testDisplayJoiningMultiWindowNoFlip() {
        // 2 windows (already H.264) + display: stays H.264 → no renegotiation.
        XCTAssertFalse(flips(from: ShareContext(windowShareCount: 2), adding: .display))
    }

    func testRemovingDisplayBackToSingleWindowFlipsH264ToVP9() {
        // window+display (H.264) → remove display → 1 window (VP9 structurally) → renegotiate up.
        let base = ShareContext(windowShareCount: 1, displayShareCount: 1) // H.264
        XCTAssertTrue(flips(from: base, removing: .display))
        XCTAssertEqual(base.removing(.display).structuralCodec, .vp9)
    }

    func testRemovingOneOfTwoWindowsFlipsH264ToVP9() {
        // 2 windows (H.264) → remove one → 1 window (VP9) → renegotiate.
        XCTAssertTrue(flips(from: ShareContext(windowShareCount: 2), removing: .window))
    }
}
