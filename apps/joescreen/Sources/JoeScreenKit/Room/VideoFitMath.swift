import Foundation
import CoreGraphics

/// Pure geometry for aspect-fit ("letterbox") video rendering and the coordinate mapping that rides
/// on top of it (spec §3.4). This fixes the M9 cursor-drift bug: a remote window renders its video
/// with `SwiftUIVideoView(layoutMode: .fit)`, which centers the video inside the view and pads the
/// remaining space with black bars when the video aspect ≠ the view aspect. The cursor's normalized
/// coordinate is defined **relative to the video content rect**, NOT the whole view — so a naive
/// `location / viewSize` mapping drifts by the letterbox padding whenever the aspects differ.
///
/// `NormalizedPoint` semantics (tightened, no wire change): `(0,0)` = top-left of the *video
/// content*, `(1,1)` = bottom-right of the *video content*. A pointer over a black bar maps to a
/// value outside `[0,1]` before clamping; callers clamp so an off-video hover pins to the edge.
///
/// All values are in a top-left-origin space (SwiftUI's local coordinate space), matching how the
/// rest of the cursor plumbing already treats normalized points.
public enum VideoFitMath {

    /// The rect the video occupies inside `viewSize` when aspect-fitted (letterboxed), top-left
    /// origin. If either the video or the view has a non-positive dimension, returns the whole view
    /// (nothing sensible to fit) so callers never divide by zero.
    /// - Parameters:
    ///   - videoAspect: video width / height (> 0).
    ///   - viewSize: the container size the video is fitted into.
    public static func contentRect(videoAspect: Double, in viewSize: CGSize) -> CGRect {
        let vw = Double(viewSize.width)
        let vh = Double(viewSize.height)
        guard videoAspect > 0, vw > 0, vh > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let viewAspect = vw / vh
        if videoAspect > viewAspect {
            // Video is relatively WIDER than the view → full width, bars top & bottom.
            let contentH = vw / videoAspect
            let y = (vh - contentH) / 2.0
            return CGRect(x: 0, y: y, width: vw, height: contentH)
        } else {
            // Video is relatively TALLER (or equal) → full height, bars left & right.
            let contentW = vh * videoAspect
            let x = (vw - contentW) / 2.0
            return CGRect(x: x, y: 0, width: contentW, height: vh)
        }
    }

    /// Map a point in the VIEW's local space to a content-relative normalized point.
    /// A hover over a black bar yields a component outside `[0,1]`; pass `clamped: true` to pin it
    /// to the video edge (the correct behavior for reporting a cursor — it never leaves the video).
    public static func normalizedPoint(
        fromViewPoint p: CGPoint,
        videoAspect: Double,
        viewSize: CGSize,
        clamped: Bool = true
    ) -> NormalizedPoint {
        let rect = contentRect(videoAspect: videoAspect, in: viewSize)
        guard rect.width > 0, rect.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        let nx = (Double(p.x) - Double(rect.minX)) / Double(rect.width)
        let ny = (Double(p.y) - Double(rect.minY)) / Double(rect.height)
        let point = NormalizedPoint(x: nx, y: ny)
        return clamped ? clamp(point) : point
    }

    /// Map a content-relative normalized point back into the VIEW's local space (for placing an
    /// inbound cursor overlay glyph over the video, aligned to the same pixel feature at both ends).
    public static func viewPoint(
        fromNormalized n: NormalizedPoint,
        videoAspect: Double,
        viewSize: CGSize
    ) -> CGPoint {
        let rect = contentRect(videoAspect: videoAspect, in: viewSize)
        let x = Double(rect.minX) + n.x * Double(rect.width)
        let y = Double(rect.minY) + n.y * Double(rect.height)
        return CGPoint(x: x, y: y)
    }

    /// Clamp a normalized point to the video content rect `[0,1]×[0,1]`.
    public static func clamp(_ p: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(x: min(max(p.x, 0.0), 1.0), y: min(max(p.y, 0.0), 1.0))
    }

    /// The size that fits `videoAspect` into at most `maxSize`, preserving aspect (used to pick an
    /// aspect-true initial window size). Never upscales past `maxSize` in either dimension.
    public static func fittedSize(videoAspect: Double, maxSize: CGSize) -> CGSize {
        let mw = Double(maxSize.width)
        let mh = Double(maxSize.height)
        guard videoAspect > 0, mw > 0, mh > 0 else { return maxSize }
        if mw / mh > videoAspect {
            // Bounding box is wider than the video → height-bound.
            return CGSize(width: mh * videoAspect, height: mh)
        } else {
            return CGSize(width: mw, height: mw / videoAspect)
        }
    }
}
