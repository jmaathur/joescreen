import XCTest
import CoreGraphics
@testable import JoeScreenKit

final class ResizeStabilizerTests: XCTestCase {

    func testSeedDoesNotEmit() {
        var s = ResizeStabilizer()
        s.seed(CGSize(width: 800, height: 500))
        XCTAssertEqual(s.committedSize, CGSize(width: 800, height: 500))
        // Re-observing the seeded size (within jitter) emits nothing.
        XCTAssertNil(s.observe(CGSize(width: 801, height: 499)))
    }

    func testJitterIsSuppressed() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 3)
        s.seed(CGSize(width: 800, height: 500))
        // ±3pt around the committed size is noise → never emits, never changes committed.
        for _ in 0..<20 {
            XCTAssertNil(s.observe(CGSize(width: 803, height: 497)))
        }
        XCTAssertEqual(s.committedSize, CGSize(width: 800, height: 500))
    }

    func testSettledResizeConfirmsAfterNSamples() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 3)
        s.seed(CGSize(width: 800, height: 500))
        let target = CGSize(width: 1000, height: 600)
        XCTAssertNil(s.observe(target)) // 1st confirmation
        XCTAssertNil(s.observe(target)) // 2nd
        XCTAssertEqual(s.observe(target), target) // 3rd → commit
        XCTAssertEqual(s.committedSize, target)
    }

    func testIntermediateDragSizesDoNotCommitUntilSettled() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 3)
        s.seed(CGSize(width: 800, height: 500))
        // A live drag: sizes keep changing → the candidate keeps resetting, nothing commits.
        XCTAssertNil(s.observe(CGSize(width: 850, height: 520)))
        XCTAssertNil(s.observe(CGSize(width: 900, height: 540)))
        XCTAssertNil(s.observe(CGSize(width: 950, height: 560)))
        XCTAssertEqual(s.committedSize, CGSize(width: 800, height: 500)) // still original
        // Now the user lets go at a final size; it settles.
        let final = CGSize(width: 1000, height: 600)
        XCTAssertNil(s.observe(final))
        XCTAssertNil(s.observe(final))
        XCTAssertEqual(s.observe(final), final)
    }

    func testSnapBackToCommittedCancelsPendingCandidate() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 3)
        s.seed(CGSize(width: 800, height: 500))
        XCTAssertNil(s.observe(CGSize(width: 1000, height: 600))) // candidate accumulating
        XCTAssertNil(s.observe(CGSize(width: 1000, height: 600)))
        // Snap back to (within jitter of) the committed size → candidate cancelled.
        XCTAssertNil(s.observe(CGSize(width: 800, height: 500)))
        // A single more sample at the old candidate must NOT immediately commit (count was reset).
        XCTAssertNil(s.observe(CGSize(width: 1000, height: 600)))
        XCTAssertEqual(s.committedSize, CGSize(width: 800, height: 500))
    }

    func testConfirmationsWithinJitterOfEachOtherStillCount() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 3)
        s.seed(CGSize(width: 800, height: 500))
        // Candidate wobbles by ≤jitter between samples but clears the committed threshold → counts.
        XCTAssertNil(s.observe(CGSize(width: 1000, height: 600)))
        XCTAssertNil(s.observe(CGSize(width: 1002, height: 599)))
        let out = s.observe(CGSize(width: 999, height: 601))
        XCTAssertNotNil(out)
        XCTAssertEqual(s.committedSize, CGSize(width: 999, height: 601))
    }

    func testStableConfirmationsOfOneCommitsImmediately() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 1)
        s.seed(CGSize(width: 800, height: 500))
        let target = CGSize(width: 1200, height: 700)
        XCTAssertEqual(s.observe(target), target)
    }

    func testFirstObserveWithoutSeedCommitsAfterConfirmations() {
        var s = ResizeStabilizer(jitterThreshold: 4, stableConfirmations: 2)
        // No seed → no committed baseline; first real size still needs confirmation.
        let target = CGSize(width: 640, height: 480)
        XCTAssertNil(s.observe(target))
        XCTAssertEqual(s.observe(target), target)
    }
}
