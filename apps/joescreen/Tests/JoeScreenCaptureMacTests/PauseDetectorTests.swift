import XCTest
@testable import JoeScreenCaptureMac

final class PauseDetectorTests: XCTestCase {

    func testCompleteFramesStayActive() {
        var d = PauseDetector(pauseAfterSeconds: 1.0)
        XCTAssertNil(d.observe(.complete, now: 0))
        XCTAssertNil(d.observe(.complete, now: 0.5))
        XCTAssertEqual(d.state, .active)
    }

    func testFrameStopAfterMotionClassifiesAsPause() {
        var d = PauseDetector(pauseAfterSeconds: 1.0)
        _ = d.observe(.complete, now: 0)          // motion establishes lastContentChange
        // Frames stop; a timer tick past the threshold detects the pause.
        XCTAssertNil(d.tick(now: 0.5))
        XCTAssertEqual(d.tick(now: 1.1), .didPause)
        XCTAssertEqual(d.state, .paused)
    }

    func testResumeOnNextCompleteFrame() {
        var d = PauseDetector(pauseAfterSeconds: 1.0)
        _ = d.observe(.complete, now: 0)
        _ = d.tick(now: 1.1) // paused
        XCTAssertEqual(d.observe(.complete, now: 2.0), .didResume)
        XCTAssertEqual(d.state, .active)
    }

    func testIdleWithoutPriorMotionIsNotPause() {
        // Static content from the start: never had motion, so a long "no complete frames" is idle,
        // not a pause — we don't tear down a share for a static window.
        var d = PauseDetector(pauseAfterSeconds: 1.0)
        XCTAssertNil(d.observe(.idle, now: 0))
        XCTAssertNil(d.tick(now: 5.0))
        XCTAssertEqual(d.state, .active)
    }

    func testSuspendedStatusPausesAfterMotion() {
        var d = PauseDetector(pauseAfterSeconds: 0.5)
        _ = d.observe(.complete, now: 0)
        // A suspended status past the threshold pauses.
        XCTAssertEqual(d.observe(.suspended, now: 0.6), .didPause)
    }

    func testNoDoublePauseTransition() {
        var d = PauseDetector(pauseAfterSeconds: 1.0)
        _ = d.observe(.complete, now: 0)
        XCTAssertEqual(d.tick(now: 1.1), .didPause)
        XCTAssertNil(d.tick(now: 2.0), "already paused → no repeat edge")
    }
}
