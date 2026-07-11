import XCTest
import CoreGraphics
@testable import JoeScreenKit

final class WindowHitTesterTests: XCTestCase {
    private let ownPID: Int32 = 999

    private func c(_ id: UInt32, pid: Int32 = 1, layer: Int = 0, _ rect: CGRect, alpha: Double = 1) -> WindowHitTester.Candidate {
        WindowHitTester.Candidate(cgWindowID: id, ownerPID: pid, layer: layer, bounds: rect, alpha: alpha)
    }

    func testFrontmostUnderCursorWins() {
        // Two overlapping windows; the FIRST (frontmost) in z-order wins.
        let front = c(1, CGRect(x: 0, y: 0, width: 400, height: 300))
        let back = c(2, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(WindowHitTester.hit(point: CGPoint(x: 100, y: 100), candidates: [front, back], ownPID: ownPID), 1)
    }

    func testCursorOutsideAllWindowsIsNil() {
        let w = c(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(WindowHitTester.hit(point: CGPoint(x: 500, y: 500), candidates: [w], ownPID: ownPID))
    }

    func testOwnWindowsSkipped() {
        let mine = c(1, pid: ownPID, CGRect(x: 0, y: 0, width: 400, height: 300))
        let theirs = c(2, pid: 5, CGRect(x: 0, y: 0, width: 400, height: 300))
        // The frontmost is ours → skipped; the next is theirs → wins.
        XCTAssertEqual(WindowHitTester.hit(point: CGPoint(x: 50, y: 50), candidates: [mine, theirs], ownPID: ownPID), 2)
    }

    func testNonZeroLayerSkipped() {
        // A menu-bar/dock window (layer != 0) under the cursor is skipped.
        let menu = c(1, layer: 25, CGRect(x: 0, y: 0, width: 1440, height: 24))
        let app = c(2, layer: 0, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(WindowHitTester.hit(point: CGPoint(x: 10, y: 10), candidates: [menu, app], ownPID: ownPID), 2)
    }

    func testTransparentSkipped() {
        let ghost = c(1, CGRect(x: 0, y: 0, width: 400, height: 300), alpha: 0)
        let real = c(2, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(WindowHitTester.hit(point: CGPoint(x: 10, y: 10), candidates: [ghost, real], ownPID: ownPID), 2)
    }

    func testTinyWindowsSkipped() {
        let tiny = c(1, CGRect(x: 0, y: 0, width: 20, height: 20))
        let real = c(2, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(WindowHitTester.hit(point: CGPoint(x: 5, y: 5), candidates: [tiny, real], ownPID: ownPID), 2)
    }

    func testEmptyCandidatesIsNil() {
        XCTAssertNil(WindowHitTester.hit(point: .zero, candidates: [], ownPID: ownPID))
    }

    func testExactBoundaryContained() {
        // CGRect.contains is inclusive of the min edge; a point on the top-left corner hits.
        let w = c(1, CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(WindowHitTester.hit(point: CGPoint(x: 100, y: 100), candidates: [w], ownPID: ownPID), 1)
    }
}
