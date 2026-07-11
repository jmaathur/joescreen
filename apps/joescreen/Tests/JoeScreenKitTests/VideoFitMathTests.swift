import XCTest
import CoreGraphics
@testable import JoeScreenKit

final class VideoFitMathTests: XCTestCase {

    private let acc = 1e-9

    // MARK: - contentRect letterbox geometry

    func testSameAspectFillsWholeView() {
        // 16:10 video in a 16:10 view → no bars, content == view.
        let rect = VideoFitMath.contentRect(videoAspect: 1.6, in: CGSize(width: 320, height: 200))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    func testWideVideoInSquareViewGetsTopBottomBars() {
        // 2:1 video in a square view → full width, bars top & bottom.
        let rect = VideoFitMath.contentRect(videoAspect: 2.0, in: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect.minX, 0, accuracy: acc)
        XCTAssertEqual(rect.width, 400, accuracy: acc)
        XCTAssertEqual(rect.height, 200, accuracy: acc) // 400 / 2
        XCTAssertEqual(rect.minY, 100, accuracy: acc)   // (400 - 200)/2
    }

    func testTallVideoInWideViewGetsLeftRightBars() {
        // Portrait 1:2 video in a landscape 2:1 view → full height, bars left & right.
        let rect = VideoFitMath.contentRect(videoAspect: 0.5, in: CGSize(width: 800, height: 400))
        XCTAssertEqual(rect.minY, 0, accuracy: acc)
        XCTAssertEqual(rect.height, 400, accuracy: acc)
        XCTAssertEqual(rect.width, 200, accuracy: acc)  // 400 * 0.5
        XCTAssertEqual(rect.minX, 300, accuracy: acc)   // (800 - 200)/2
    }

    func testDegenerateInputsReturnWholeView() {
        let size = CGSize(width: 100, height: 50)
        XCTAssertEqual(VideoFitMath.contentRect(videoAspect: 0, in: size), CGRect(origin: .zero, size: size))
        XCTAssertEqual(VideoFitMath.contentRect(videoAspect: 1.6, in: .zero), CGRect(origin: .zero, size: .zero))
    }

    // MARK: - normalized ↔ view round-trip (the cursor-drift fix)

    func testRoundTripCenterAcrossLetterbox() {
        // The KEY case: with top/bottom bars, view-center must map to normalized (0.5, 0.5) and back.
        let viewSize = CGSize(width: 400, height: 400)
        let aspect = 2.0
        let center = CGPoint(x: 200, y: 200)
        let n = VideoFitMath.normalizedPoint(fromViewPoint: center, videoAspect: aspect, viewSize: viewSize)
        XCTAssertEqual(n.x, 0.5, accuracy: acc)
        XCTAssertEqual(n.y, 0.5, accuracy: acc)
        let back = VideoFitMath.viewPoint(fromNormalized: n, videoAspect: aspect, viewSize: viewSize)
        XCTAssertEqual(back.x, center.x, accuracy: acc)
        XCTAssertEqual(back.y, center.y, accuracy: acc)
    }

    func testTopOfVideoContentMapsToZeroNotTopOfView() {
        // With a 100pt top bar, the video's top edge is at view y=100 and must be normalized y=0 —
        // the exact bug the naive `location / viewSize` mapping got wrong (it gave 0.25).
        let viewSize = CGSize(width: 400, height: 400)
        let aspect = 2.0 // content 400x200 centered → top bar 100pt
        let atVideoTop = CGPoint(x: 200, y: 100)
        let n = VideoFitMath.normalizedPoint(fromViewPoint: atVideoTop, videoAspect: aspect, viewSize: viewSize)
        XCTAssertEqual(n.y, 0.0, accuracy: acc)
        XCTAssertNotEqual(n.y, 0.25, accuracy: acc)
    }

    func testHoverOverBarClampsToEdge() {
        // A hover in the top black bar (above the video) clamps to y=0, never negative.
        let viewSize = CGSize(width: 400, height: 400)
        let aspect = 2.0
        let inBar = CGPoint(x: 200, y: 20) // above the video's top at y=100
        let n = VideoFitMath.normalizedPoint(fromViewPoint: inBar, videoAspect: aspect, viewSize: viewSize)
        XCTAssertEqual(n.y, 0.0, accuracy: acc)
        XCTAssertGreaterThanOrEqual(n.y, 0.0)
    }

    func testUnclampedRevealsBarPosition() {
        let viewSize = CGSize(width: 400, height: 400)
        let aspect = 2.0
        let inBar = CGPoint(x: 200, y: 0) // view top, 100pt above the video
        let n = VideoFitMath.normalizedPoint(fromViewPoint: inBar, videoAspect: aspect,
                                             viewSize: viewSize, clamped: false)
        XCTAssertEqual(n.y, -0.5, accuracy: acc) // (0 - 100) / 200
    }

    func testRoundTripCornersWithSideBars() {
        let viewSize = CGSize(width: 800, height: 400)
        let aspect = 0.5 // content 200x400 centered → left bar at x=300
        for n in [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 1, y: 1), NormalizedPoint(x: 0.3, y: 0.7)] {
            let v = VideoFitMath.viewPoint(fromNormalized: n, videoAspect: aspect, viewSize: viewSize)
            let back = VideoFitMath.normalizedPoint(fromViewPoint: v, videoAspect: aspect,
                                                    viewSize: viewSize, clamped: false)
            XCTAssertEqual(back.x, n.x, accuracy: acc)
            XCTAssertEqual(back.y, n.y, accuracy: acc)
        }
    }

    // MARK: - fittedSize

    func testFittedSizeNeverUpscalesAndKeepsAspect() {
        // 16:9 into a 1000x1000 box → width-... no: 16:9 aspect > 1 → wider than tall, height-bound? test.
        let s = VideoFitMath.fittedSize(videoAspect: 16.0/9.0, maxSize: CGSize(width: 1000, height: 1000))
        // box is square (aspect 1) < video aspect 1.777 → width-bound: width=1000, height=562.5
        XCTAssertEqual(s.width, 1000, accuracy: acc)
        XCTAssertEqual(s.height, 562.5, accuracy: acc)
        XCTAssertLessThanOrEqual(s.width, 1000)
        XCTAssertLessThanOrEqual(s.height, 1000)
    }

    func testFittedSizeHeightBound() {
        // Portrait 9:16 into a wide box → height-bound.
        let s = VideoFitMath.fittedSize(videoAspect: 9.0/16.0, maxSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(s.height, 500, accuracy: acc)
        XCTAssertEqual(s.width, 500 * 9.0/16.0, accuracy: acc)
    }
}
