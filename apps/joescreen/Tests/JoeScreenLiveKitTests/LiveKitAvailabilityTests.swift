import XCTest
@testable import JoeScreenLiveKit

/// M0 placeholder proving the LiveKit-linking target and its test target resolve/build. The real
/// M2 integration suite (two Rooms in one process, six-channel round-trip, identity binding) lives
/// alongside and SKIPS unless `LIVEKIT_URL` is set.
final class LiveKitAvailabilityTests: XCTestCase {
    func testLiveKitSDKLinks() {
        XCTAssertTrue(LiveKitAvailability.linkCheck())
        XCTAssertEqual(LiveKitAvailability.sdkPinnedVersion, "2.15.1")
    }
}
