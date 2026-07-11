import Foundation

/// Picks the capture pixel size for a whole-display share (spec §M11). Pure math, unit-tested.
///
/// Source pixels = display points × `pointPixelScale` (Retina). A 5K display is ~14.7 Mpx — far too
/// much to encode at 30 fps for legibility, so we cap the AREA at a 4.096 Mpx budget (≈2560×1600),
/// preserving the display's aspect, snapping both dimensions EVEN (encoders want even dims), and
/// NEVER upscaling (a small display captures at its native pixels). A 5K display lands ≈2389×1344;
/// a 1080p display stays 1920×1080.
public enum DisplayResolutionPolicy {

    /// Max captured pixel AREA (≈2560×1600). Above this we scale down preserving aspect.
    public static let maxPixelArea: Double = 4_096_000

    public struct Resolution: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    /// Compute the capture resolution for a display.
    /// - Parameters:
    ///   - pointWidth: display width in points (`SCDisplay.width`).
    ///   - pointHeight: display height in points (`SCDisplay.height`).
    ///   - pointPixelScale: backing scale (`SCContentFilter.pointPixelScale`; 1 for non-Retina, 2 for Retina).
    public static func resolution(pointWidth: Int, pointHeight: Int, pointPixelScale: Double) -> Resolution {
        let scale = pointPixelScale <= 0 ? 1.0 : pointPixelScale
        let srcW = Double(max(1, pointWidth)) * scale
        let srcH = Double(max(1, pointHeight)) * scale
        let area = srcW * srcH

        var w = srcW
        var h = srcH
        if area > maxPixelArea {
            // Scale both dims by sqrt(budget/area) to hit the area cap while preserving aspect.
            let factor = (maxPixelArea / area).squareRoot()
            w = srcW * factor
            h = srcH * factor
        }
        // Never upscale past source; snap even (floor to even so we never exceed the budget).
        return Resolution(width: evenFloor(min(w, srcW)), height: evenFloor(min(h, srcH)))
    }

    /// Floor to the nearest even integer, at least 2.
    private static func evenFloor(_ v: Double) -> Int {
        let n = Int(v)
        let even = n - (n % 2)
        return max(2, even)
    }
}
