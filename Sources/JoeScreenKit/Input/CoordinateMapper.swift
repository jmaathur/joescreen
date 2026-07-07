import Foundation
import CoreGraphics

/// Maps normalized [0,1] remote coordinates into the owner Mac's global CG coordinate space for
/// injection, and clamps them to the shared window's bounds (the security clamp — a malicious peer
/// must never address pixels outside the window it was granted, spec §3.5).
///
/// Two coordinate subtleties are handled explicitly (spec §3.4/§3.5):
///  • Normalized space is top-left origin (matches CGEvent's global top-left origin), so no Y-flip
///    is needed to produce a CGEvent point. AppKit's bottom-left `NSWindow.frame` is converted to
///    CG top-left ONCE, at the boundary, via `WindowBounds.fromAppKit`.
///  • Receiver-side local window scaling (the viewer resized the remote window) does NOT change the
///    mapping: coordinates are always resolved against the OWNER's real window bounds, which the
///    normalized value indexes into. Local resize is a pure display transform on the receiver.
public struct WindowBounds: Sendable, Equatable {
    /// The window's frame in the OWNER's global CG space (top-left origin, points).
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX; self.originY = originY; self.width = width; self.height = height
    }

    /// Build CG-space (top-left) bounds from an AppKit bottom-left frame.
    /// - Parameters:
    ///   - appKitFrame: `(x, y, w, h)` with y measured from the bottom of `globalHeight`.
    ///   - globalHeight: total height of the global coordinate space (e.g. main-display or
    ///     desktop-union height) used to flip the origin.
    public static func fromAppKit(
        x: Double, y: Double, width: Double, height: Double, globalHeight: Double
    ) -> WindowBounds {
        // AppKit bottom-left → CG top-left: newTop = globalHeight - (y + height).
        WindowBounds(originX: x, originY: globalHeight - (y + height), width: width, height: height)
    }
}

public struct CoordinateMapper: Sendable {
    public init() {}

    /// Whether a normalized point is inside [0,1]×[0,1] (i.e. within the window before clamping).
    public func isInside(_ p: NormalizedPoint) -> Bool {
        (0.0...1.0).contains(p.x) && (0.0...1.0).contains(p.y)
    }

    /// Clamp a normalized point to [0,1]. Applied BEFORE mapping so out-of-window addresses are
    /// pinned to the window edge rather than leaking into neighboring windows/apps.
    public func clampNormalized(_ p: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(x: min(max(p.x, 0.0), 1.0), y: min(max(p.y, 0.0), 1.0))
    }

    /// Map a (clamped) normalized point into the owner's global CG point for injection.
    /// The `backingScale` (Retina) does not affect the *point* value (CGEvent works in points, not
    /// pixels); it is accepted for callers that need to translate to backing pixels elsewhere.
    public func toGlobalCGPoint(
        _ normalized: NormalizedPoint,
        in bounds: WindowBounds,
        backingScale: Double = 1.0
    ) -> CGPoint {
        let clamped = clampNormalized(normalized)
        let gx = bounds.originX + clamped.x * bounds.width
        let gy = bounds.originY + clamped.y * bounds.height
        return CGPoint(x: gx, y: gy)
    }

    /// Convert a global CG point captured on the SENDER back into normalized window space (used
    /// when a Mac reports its own cursor position to peers).
    public func toNormalized(_ global: CGPoint, in bounds: WindowBounds) -> NormalizedPoint {
        guard bounds.width > 0, bounds.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        let nx = (Double(global.x) - bounds.originX) / bounds.width
        let ny = (Double(global.y) - bounds.originY) / bounds.height
        return NormalizedPoint(x: nx, y: ny)
    }
}
