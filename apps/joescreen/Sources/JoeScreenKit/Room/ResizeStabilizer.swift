import Foundation
import CoreGraphics

/// Debounces a live stream of a shared window's size so a full `SCStream.updateConfiguration` (an
/// expensive keyframe-forcing operation) fires only on a *settled, meaningful* resize — not on every
/// sub-pixel jitter or mid-drag intermediate frame (spec §3 / M9). Pure logic: the capture side
/// feeds it polled sizes; it returns a confirmed new size exactly once per settled change.
///
/// Two guards:
///  1. **Jitter suppression** — a candidate within `jitterThreshold` points of the last COMMITTED
///     size (in both width and height) is ignored entirely (drag-handle noise, rounding).
///  2. **Stable confirmation** — a candidate that clears the jitter threshold must repeat
///     (within jitter tolerance of itself) for `stableConfirmations` consecutive samples before it
///     commits. This waits out the intermediate sizes of a live drag and only reconfigures once the
///     user lets go.
public struct ResizeStabilizer: Sendable, Equatable {

    /// Points of change below which a candidate is treated as noise (both axes). Default 4 pt.
    public let jitterThreshold: Double
    /// Consecutive stable samples required to confirm a new size. Default 3.
    public let stableConfirmations: Int

    /// The last committed (reported-out) size. `nil` until the first `seed`/commit.
    public private(set) var committedSize: CGSize?

    // The candidate currently accumulating confirmations, and how many it has.
    private var pendingSize: CGSize?
    private var pendingCount: Int

    public init(jitterThreshold: Double = 4.0, stableConfirmations: Int = 3) {
        self.jitterThreshold = max(0, jitterThreshold)
        self.stableConfirmations = max(1, stableConfirmations)
        self.committedSize = nil
        self.pendingSize = nil
        self.pendingCount = 0
    }

    /// Seed the initial committed size (the size at capture start) WITHOUT emitting a confirmation.
    public mutating func seed(_ size: CGSize) {
        committedSize = size
        pendingSize = nil
        pendingCount = 0
    }

    /// Offer a freshly-observed size. Returns the confirmed new size EXACTLY when a settled resize
    /// has been detected (and updates `committedSize`); returns `nil` otherwise (noise, or still
    /// accumulating confirmations).
    public mutating func observe(_ size: CGSize) -> CGSize? {
        // Ignore pure jitter around the committed size.
        if let committed = committedSize, within(size, committed, jitterThreshold) {
            // Snapping back to the committed size cancels any in-flight candidate.
            pendingSize = nil
            pendingCount = 0
            return nil
        }

        // Accumulate confirmations for a candidate that has cleared the jitter threshold.
        if let pending = pendingSize, within(size, pending, jitterThreshold) {
            pendingCount += 1
        } else {
            pendingSize = size
            pendingCount = 1
        }

        if pendingCount >= stableConfirmations {
            committedSize = size
            pendingSize = nil
            pendingCount = 0
            return size
        }
        return nil
    }

    /// Whether two sizes are within `tol` points on BOTH axes.
    private func within(_ a: CGSize, _ b: CGSize, _ tol: Double) -> Bool {
        abs(Double(a.width - b.width)) <= tol && abs(Double(a.height - b.height)) <= tol
    }
}
