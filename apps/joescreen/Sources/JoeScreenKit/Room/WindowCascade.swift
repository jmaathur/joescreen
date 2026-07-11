import Foundation
import CoreGraphics

/// Deterministic placement for remote-share viewer windows (spec §3 / M9). Replaces the old
/// `CGFloat(windows.count) * 30` cascade in `RemoteWindowManager`, which mixed windows from all
/// owners into one stack and had no clamping. Here each OWNER gets a distinct anchor (so one peer's
/// windows cluster together, visually grouped), and each of that owner's windows cascades from the
/// anchor. Fully pure: the same inputs always yield the same frame, so it is unit-testable and two
/// receivers lay windows out identically.
///
/// Coordinates are AppKit screen coordinates (bottom-left origin), matching `NSScreen.visibleFrame`
/// and `NSWindow.setFrame`. The result is always fully inside `visibleFrame` (clamped), so a window
/// never opens partly or wholly off-screen no matter how deep the cascade.
public enum WindowCascade {

    /// Per-owner horizontal/vertical anchor step (points). Distinct owners start their stacks apart.
    public static let ownerAnchorStep = CGSize(width: 48, height: 40)
    /// Per-window cascade step within one owner's stack (points), classic top-left march.
    public static let windowCascadeStep = CGSize(width: 28, height: 28)

    /// Compute the placement frame for one viewer window.
    /// - Parameters:
    ///   - size: the window's content size (already aspect-fitted by the caller).
    ///   - ownerIndex: stable index of the owner among current owners (e.g. sorted by UUID) — the
    ///     anchor selector. Clamped to ≥ 0.
    ///   - windowIndex: stable index of this window within that owner's windows (sorted by UUID) —
    ///     the cascade depth. Clamped to ≥ 0.
    ///   - visibleFrame: the screen's usable area (AppKit bottom-left origin), e.g.
    ///     `NSScreen.visibleFrame`. The returned frame is clamped fully inside it.
    public static func frame(
        size: CGSize,
        ownerIndex: Int,
        windowIndex: Int,
        visibleFrame: CGRect
    ) -> CGRect {
        let oi = max(ownerIndex, 0)
        let wi = max(windowIndex, 0)

        // A window larger than the visible area is shrunk to fit (defensive; the caller normally
        // fits it first). Preserves aspect is the caller's job — here we just clamp dimensions.
        let w = min(size.width, visibleFrame.width)
        let h = min(size.height, visibleFrame.height)

        // Anchor near the top-left of the visible area (AppKit: high Y is the top). Owners fan out;
        // windows within an owner cascade down-right from that owner's anchor.
        let anchorX = visibleFrame.minX
            + CGFloat(oi) * ownerAnchorStep.width
            + CGFloat(wi) * windowCascadeStep.width
        // Top edge marches DOWN (subtract from the top) as indices grow.
        let topY = visibleFrame.maxY
            - CGFloat(oi) * ownerAnchorStep.height
            - CGFloat(wi) * windowCascadeStep.height
        // Convert desired top edge to a bottom-left origin.
        let originYFromTop = topY - h

        // Clamp fully inside visibleFrame. If the cascade marched a window off an edge, it pins to
        // the nearest in-bounds position rather than opening off-screen.
        let clampedX = clamp(anchorX, lower: visibleFrame.minX, upper: visibleFrame.maxX - w)
        let clampedY = clamp(originYFromTop, lower: visibleFrame.minY, upper: visibleFrame.maxY - h)
        return CGRect(x: clampedX, y: clampedY, width: w, height: h)
    }

    private static func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        // `upper` can fall below `lower` when the window is nearly as large as the screen; in that
        // case pin to `lower` (top-left corner) so the result stays well-defined.
        guard upper > lower else { return lower }
        return min(max(v, lower), upper)
    }
}
