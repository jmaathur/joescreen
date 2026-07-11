import Foundation
import CoreGraphics

/// Resolves which display a picker selection refers to on the macOS-14.0–15.1 floor, where
/// `SCContentFilter.includedDisplays` is unavailable (15.2+). The filter still exposes
/// `contentRect` (14.0+) and `style` (14.0+), so for a display-style pick we match the content rect
/// against the known display frames — display frames are UNIQUE in global coordinate space, so an
/// exact (or near-exact) frame match uniquely identifies the display (spec §M11 macOS-14 floor fix).
///
/// Pure logic: the app hands it the candidate `(displayID, frame)` list from
/// `SCShareableContent.displays` and the filter's content rect; it returns the matching displayID.
public enum DisplayPickResolver {

    /// One candidate display: its `CGDirectDisplayID` and global frame (points).
    public struct Candidate: Sendable, Equatable {
        public let displayID: UInt32
        public let frame: CGRect
        public init(displayID: UInt32, frame: CGRect) {
            self.displayID = displayID
            self.frame = frame
        }
    }

    /// Match `contentRect` to a display. Prefers an exact frame match; falls back to the closest by
    /// origin+size within `tolerance` points. Returns nil if none is within tolerance (ambiguous —
    /// the caller shows a "please retry" notice).
    /// - Parameter tolerance: max per-edge deviation (points) for a fuzzy match. Default 2 pt.
    public static func resolve(
        contentRect: CGRect,
        candidates: [Candidate],
        tolerance: CGFloat = 2.0
    ) -> UInt32? {
        // Exact match first.
        if let exact = candidates.first(where: { $0.frame == contentRect }) {
            return exact.displayID
        }
        // Closest within tolerance (guards against sub-point rounding). Score = max edge deviation.
        var best: (id: UInt32, score: CGFloat)?
        for c in candidates {
            let dx = abs(c.frame.minX - contentRect.minX)
            let dy = abs(c.frame.minY - contentRect.minY)
            let dw = abs(c.frame.width - contentRect.width)
            let dh = abs(c.frame.height - contentRect.height)
            let score = max(max(dx, dy), max(dw, dh))
            if score <= tolerance, best == nil || score < best!.score {
                best = (c.displayID, score)
            }
        }
        return best?.id
    }
}
