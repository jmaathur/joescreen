import Foundation

/// Bounded exponential backoff for recovering a failed remote-track subscription (the join-time
/// race in LiveKit client-sdk-swift 2.15.1: when media arrives before the publication's
/// participant-info update, the SDK's engine retries only 2×0.2s, then drops the received media
/// and reports `didFailToSubscribeTrackWithSid` with nothing left to re-attach it). The concrete
/// retry loop lives in JoeScreenLiveKit's `LiveKitTransport`; this pure value type owns the
/// schedule so the policy is unit-testable offline (no SFU, no devices).
public struct SubscriptionRetryPolicy: Sendable, Equatable {

    /// Total attempts, including the immediate first one.
    public var maxAttempts: Int
    /// Delay before the SECOND attempt (seconds); doubles per attempt, capped at `maxDelay`.
    public var initialDelay: Double
    /// Upper bound for any single delay (seconds).
    public var maxDelay: Double

    public init(maxAttempts: Int = 5, initialDelay: Double = 0.5, maxDelay: Double = 8.0) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    /// The delay to wait BEFORE `attempt` (0-based). The first attempt is immediate; attempt n
    /// waits `initialDelay × 2^(n−1)`, capped at `maxDelay`.
    public func delay(beforeAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return 0 }
        let delay = initialDelay * pow(2.0, Double(attempt - 1))
        return min(delay, maxDelay)
    }
}
