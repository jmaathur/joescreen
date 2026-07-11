import XCTest
import CoreGraphics
@testable import JoeScreenKit

final class WindowCascadeTests: XCTestCase {

    // A generous visible frame (bottom-left origin), big enough that early cascades don't clamp.
    private let visible = CGRect(x: 0, y: 0, width: 2000, height: 1400)
    private let size = CGSize(width: 800, height: 500)

    func testDeterministicForSameInputs() {
        let a = WindowCascade.frame(size: size, ownerIndex: 1, windowIndex: 2, visibleFrame: visible)
        let b = WindowCascade.frame(size: size, ownerIndex: 1, windowIndex: 2, visibleFrame: visible)
        XCTAssertEqual(a, b)
    }

    func testFirstWindowAnchorsTopLeft() {
        // owner 0, window 0 → anchored at the top-left of the visible frame (AppKit: top = maxY).
        let f = WindowCascade.frame(size: size, ownerIndex: 0, windowIndex: 0, visibleFrame: visible)
        XCTAssertEqual(f.minX, visible.minX, accuracy: 1e-9)
        XCTAssertEqual(f.maxY, visible.maxY, accuracy: 1e-9) // top edge flush with the top
        XCTAssertEqual(f.size, size)
    }

    func testWindowsCascadeDownRightWithinOwner() {
        let f0 = WindowCascade.frame(size: size, ownerIndex: 0, windowIndex: 0, visibleFrame: visible)
        let f1 = WindowCascade.frame(size: size, ownerIndex: 0, windowIndex: 1, visibleFrame: visible)
        // Window 1 is to the right of and below window 0 (top edge lower).
        XCTAssertGreaterThan(f1.minX, f0.minX)
        XCTAssertLessThan(f1.maxY, f0.maxY)
        XCTAssertEqual(f1.minX - f0.minX, WindowCascade.windowCascadeStep.width, accuracy: 1e-9)
    }

    func testDistinctOwnersGetDistinctAnchors() {
        let owner0 = WindowCascade.frame(size: size, ownerIndex: 0, windowIndex: 0, visibleFrame: visible)
        let owner1 = WindowCascade.frame(size: size, ownerIndex: 1, windowIndex: 0, visibleFrame: visible)
        XCTAssertNotEqual(owner0.origin, owner1.origin)
        XCTAssertEqual(owner1.minX - owner0.minX, WindowCascade.ownerAnchorStep.width, accuracy: 1e-9)
    }

    func testAlwaysClampedInsideVisibleFrame() {
        // Deep cascades must never escape the visible frame.
        for oi in 0..<10 {
            for wi in 0..<40 {
                let f = WindowCascade.frame(size: size, ownerIndex: oi, windowIndex: wi, visibleFrame: visible)
                XCTAssertGreaterThanOrEqual(f.minX, visible.minX - 1e-6, "oi=\(oi) wi=\(wi)")
                XCTAssertGreaterThanOrEqual(f.minY, visible.minY - 1e-6, "oi=\(oi) wi=\(wi)")
                XCTAssertLessThanOrEqual(f.maxX, visible.maxX + 1e-6, "oi=\(oi) wi=\(wi)")
                XCTAssertLessThanOrEqual(f.maxY, visible.maxY + 1e-6, "oi=\(oi) wi=\(wi)")
            }
        }
    }

    func testOversizeWindowShrinksToFitAndPinsTopLeft() {
        let huge = CGSize(width: 5000, height: 5000)
        let f = WindowCascade.frame(size: huge, ownerIndex: 3, windowIndex: 5, visibleFrame: visible)
        XCTAssertLessThanOrEqual(f.width, visible.width)
        XCTAssertLessThanOrEqual(f.height, visible.height)
        XCTAssertGreaterThanOrEqual(f.minX, visible.minX - 1e-6)
        XCTAssertLessThanOrEqual(f.maxY, visible.maxY + 1e-6)
    }

    func testNegativeIndicesClampToZero() {
        let f = WindowCascade.frame(size: size, ownerIndex: -5, windowIndex: -3, visibleFrame: visible)
        let f0 = WindowCascade.frame(size: size, ownerIndex: 0, windowIndex: 0, visibleFrame: visible)
        XCTAssertEqual(f, f0)
    }

    func testNonZeroOriginVisibleFrameRespected() {
        // A secondary display / menu-bar-inset frame with a non-zero origin.
        let offset = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let f = WindowCascade.frame(size: size, ownerIndex: 0, windowIndex: 0, visibleFrame: offset)
        XCTAssertEqual(f.minX, offset.minX, accuracy: 1e-9)
        XCTAssertEqual(f.maxY, offset.maxY, accuracy: 1e-9)
    }
}
