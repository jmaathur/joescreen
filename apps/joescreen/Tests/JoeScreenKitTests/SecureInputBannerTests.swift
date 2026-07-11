import XCTest
@testable import JoeScreenKit

final class SecureInputBannerTests: XCTestCase {
    func testBannerOnlyWhenActiveAndDriving() {
        XCTAssertEqual(SecureInputBanner.decide(secureInputActive: true, someoneIsDriving: true), .secureInputBlocking)
    }
    func testNoBannerWhenNobodyDriving() {
        // Secure input active but nobody is remote-controlling → no alarming banner.
        XCTAssertEqual(SecureInputBanner.decide(secureInputActive: true, someoneIsDriving: false), .none)
    }
    func testNoBannerWhenNotSecure() {
        XCTAssertEqual(SecureInputBanner.decide(secureInputActive: false, someoneIsDriving: true), .none)
        XCTAssertEqual(SecureInputBanner.decide(secureInputActive: false, someoneIsDriving: false), .none)
    }
}
