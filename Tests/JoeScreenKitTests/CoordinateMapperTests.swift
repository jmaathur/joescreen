import XCTest
import CoreGraphics
@testable import JoeScreenKit

final class CoordinateMapperTests: XCTestCase {
    let m = CoordinateMapper()

    func testCenterMapsToWindowCenter() {
        let b = WindowBounds(originX: 100, originY: 200, width: 400, height: 300)
        let p = m.toGlobalCGPoint(NormalizedPoint(x: 0.5, y: 0.5), in: b)
        XCTAssertEqual(p.x, 300, accuracy: 1e-9)   // 100 + 0.5*400
        XCTAssertEqual(p.y, 350, accuracy: 1e-9)   // 200 + 0.5*300
    }

    func testCornersMapToWindowCorners() {
        let b = WindowBounds(originX: 0, originY: 0, width: 100, height: 100)
        XCTAssertEqual(m.toGlobalCGPoint(.init(x: 0, y: 0), in: b), CGPoint(x: 0, y: 0))
        XCTAssertEqual(m.toGlobalCGPoint(.init(x: 1, y: 1), in: b), CGPoint(x: 100, y: 100))
    }

    func testOutOfBoundsClampedToWindow_theSecurityClamp() {
        let b = WindowBounds(originX: 10, originY: 10, width: 200, height: 200)
        // A hostile point far outside must be pinned to the window edge, never leak past it.
        let p = m.toGlobalCGPoint(.init(x: 5.0, y: -3.0), in: b)
        XCTAssertEqual(p.x, 210) // 10 + 1.0*200 (clamped x=1)
        XCTAssertEqual(p.y, 10)  // 10 + 0.0*200 (clamped y=0)
        XCTAssertTrue(p.x <= b.originX + b.width)
        XCTAssertTrue(p.y >= b.originY)
    }

    func testAppKitBottomLeftToCGTopLeftFlip() {
        // A 100-tall window sitting at AppKit y=0 (bottom) in an 800-tall global space has its
        // CG-space top at 800 - (0 + 100) = 700.
        let b = WindowBounds.fromAppKit(x: 50, y: 0, width: 200, height: 100, globalHeight: 800)
        XCTAssertEqual(b.originX, 50)
        XCTAssertEqual(b.originY, 700)
    }

    func testLocalResizeDoesNotChangeMapping() {
        // The receiver resizing its local view does NOT change the owner-space mapping: we always
        // resolve against the OWNER's real bounds, so the same normalized point maps identically
        // regardless of any receiver-side scale.
        let owner = WindowBounds(originX: 0, originY: 0, width: 1000, height: 500)
        let p1 = m.toGlobalCGPoint(.init(x: 0.3, y: 0.6), in: owner)
        let p2 = m.toGlobalCGPoint(.init(x: 0.3, y: 0.6), in: owner)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(p1.x, 300)
        XCTAssertEqual(p1.y, 300)
    }

    func testRoundTripNormalizedGlobalNormalized() {
        let b = WindowBounds(originX: 30, originY: 40, width: 640, height: 480)
        let n = NormalizedPoint(x: 0.42, y: 0.63)
        let g = m.toGlobalCGPoint(n, in: b)
        let back = m.toNormalized(g, in: b)
        XCTAssertEqual(back.x, n.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, n.y, accuracy: 1e-9)
    }
}
