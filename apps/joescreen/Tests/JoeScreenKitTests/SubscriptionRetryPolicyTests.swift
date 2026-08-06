import XCTest
@testable import JoeScreenKit

final class SubscriptionRetryPolicyTests: XCTestCase {

    func testFirstAttemptIsImmediate() {
        XCTAssertEqual(SubscriptionRetryPolicy().delay(beforeAttempt: 0), 0)
    }

    func testDelaysDoubleExponentially() {
        let policy = SubscriptionRetryPolicy(initialDelay: 0.5)
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 1.0, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 2.0, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 4), 4.0, accuracy: 1e-9)
    }

    func testDelayIsCappedAtMax() {
        let policy = SubscriptionRetryPolicy(initialDelay: 0.5, maxDelay: 8.0)
        XCTAssertEqual(policy.delay(beforeAttempt: 10), 8.0, accuracy: 1e-9)
    }

    func testDefaultsAreFiveAttemptsStartingAtHalfASecond() {
        let policy = SubscriptionRetryPolicy()
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.initialDelay, 0.5, accuracy: 1e-9)
    }

    func testMaxAttemptsFloorIsOne() {
        XCTAssertEqual(SubscriptionRetryPolicy(maxAttempts: 0).maxAttempts, 1)
    }
}
