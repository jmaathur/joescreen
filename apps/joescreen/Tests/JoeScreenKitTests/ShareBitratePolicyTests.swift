import XCTest
@testable import JoeScreenKit

final class ShareBitratePolicyTests: XCTestCase {

    func test1080pIsAboutTwoAndHalfMbps() {
        // 1920×1080 × 30 × 0.04 = 2.488 Mbps.
        let bps = ShareBitratePolicy.bitrate(pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(bps, 1920.0 * 1080 * 30 * 0.04, accuracy: 1.0)
        XCTAssertGreaterThan(bps, 2_400_000)
        XCTAssertLessThan(bps, 2_600_000)
    }

    func testCapped5KLandsUnderCeiling() {
        // A capped 5K display ≈2389×1344 × 30 × 0.04 ≈ 3.85 Mbps — under the 8 Mbps ceiling.
        let bps = ShareBitratePolicy.bitrate(pixelWidth: 2389, pixelHeight: 1344)
        XCTAssertLessThan(bps, ShareBitratePolicy.ceilingBps)
        XCTAssertGreaterThan(bps, 3_500_000)
    }

    func testTinyWindowFlooredAtOneMbps() {
        // A 200×150 window would compute ~36 kbps — floored to 1 Mbps for legibility.
        let bps = ShareBitratePolicy.bitrate(pixelWidth: 200, pixelHeight: 150)
        XCTAssertEqual(bps, ShareBitratePolicy.floorBps)
    }

    func testHugeSurfaceCappedAtCeiling() {
        // An uncapped 8K surface would exceed 8 Mbps — clamped to the ceiling.
        let bps = ShareBitratePolicy.bitrate(pixelWidth: 7680, pixelHeight: 4320)
        XCTAssertEqual(bps, ShareBitratePolicy.ceilingBps)
    }

    func testZeroDimensionsFloored() {
        XCTAssertEqual(ShareBitratePolicy.bitrate(pixelWidth: 0, pixelHeight: 0), ShareBitratePolicy.floorBps)
    }
}
