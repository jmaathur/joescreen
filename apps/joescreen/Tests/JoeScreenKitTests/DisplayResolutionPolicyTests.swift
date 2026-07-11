import XCTest
@testable import JoeScreenKit

final class DisplayResolutionPolicyTests: XCTestCase {

    private func res(_ w: Int, _ h: Int, scale: Double) -> DisplayResolutionPolicy.Resolution {
        DisplayResolutionPolicy.resolution(pointWidth: w, pointHeight: h, pointPixelScale: scale)
    }

    func test1080pNonRetinaStaysNative() {
        // 1920×1080 × 1 = 2.07 Mpx ≤ 4.096 Mpx budget → native.
        XCTAssertEqual(res(1920, 1080, scale: 1), .init(width: 1920, height: 1080))
    }

    func test5KRetinaCapsUnderBudgetPreservingAspect() {
        // A 5K display: 2560×1440 points × 2 = 5120×2880 = 14.7 Mpx → scale to the 4.096 Mpx budget.
        let r = res(2560, 1440, scale: 2)
        let area = Double(r.width * r.height)
        XCTAssertLessThanOrEqual(area, DisplayResolutionPolicy.maxPixelArea + 1)
        // Aspect preserved (16:9 ≈ 1.777).
        XCTAssertEqual(Double(r.width) / Double(r.height), 16.0/9.0, accuracy: 0.02)
        // Lands ≈2700×1518 for a 16:9 5K (both even).
        XCTAssertEqual(r.width % 2, 0)
        XCTAssertEqual(r.height % 2, 0)
        XCTAssertGreaterThan(r.width, 2000)
    }

    func testNeverUpscalesSmallDisplay() {
        // A tiny 800×600 non-Retina display stays 800×600 (never upscaled to fill the budget).
        XCTAssertEqual(res(800, 600, scale: 1), .init(width: 800, height: 600))
    }

    func testDimensionsAlwaysEven() {
        // An odd-point display at scale 1 → floored to even.
        let r = res(1365, 767, scale: 1)
        XCTAssertEqual(r.width % 2, 0)
        XCTAssertEqual(r.height % 2, 0)
        XCTAssertLessThanOrEqual(r.width, 1365)
        XCTAssertLessThanOrEqual(r.height, 767)
    }

    func testAreaCappedForHugeSurface() {
        // 4K Retina: 3840×2160 × 2 = huge → capped.
        let r = res(3840, 2160, scale: 2)
        XCTAssertLessThanOrEqual(Double(r.width * r.height), DisplayResolutionPolicy.maxPixelArea + 1)
    }

    func testCappedNeverExceedsBudget() {
        // Property-ish sweep: several sizes/scales, capped result never exceeds the budget and never
        // upscales past source pixels.
        for (w, h, s) in [(2560, 1600, 2.0), (5120, 2880, 1.0), (1440, 900, 2.0), (3008, 1692, 2.0)] {
            let src = Double(w) * s * Double(h) * s
            let r = res(w, h, scale: s)
            XCTAssertLessThanOrEqual(Double(r.width * r.height), DisplayResolutionPolicy.maxPixelArea + 1, "w=\(w) h=\(h) s=\(s)")
            XCTAssertLessThanOrEqual(Double(r.width), Double(w) * s + 1)
            XCTAssertLessThanOrEqual(Double(r.height), Double(h) * s + 1)
            _ = src
        }
    }

    func testZeroScaleTreatedAsOne() {
        XCTAssertEqual(res(1920, 1080, scale: 0), .init(width: 1920, height: 1080))
    }
}
