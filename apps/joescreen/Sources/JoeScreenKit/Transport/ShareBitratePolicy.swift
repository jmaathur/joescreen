import Foundation

/// Picks a target bitrate for one share track from its pixel dimensions (spec §3 / M11). Pure math,
/// unit-tested; the value becomes real via `VideoPublishOptions.screenShareEncoding`.
///
/// Model: `pixelArea × fps × bitsPerPixel`, clamped to a sane floor/ceiling. `bitsPerPixel` (0.04)
/// is a screen-content constant tuned for legibility over motion; a 1080p window lands ≈2.5 Mbps and
/// a capped 5K display ≈3.9 Mbps. The floor keeps tiny windows legible; the ceiling caps a single
/// track's share of the uplink (admission then degrades the WHOLE set if the sum doesn't fit).
public enum ShareBitratePolicy {
    /// Screen-content bits-per-pixel-per-frame (legibility-tuned; ASSUMED pending Phase-0(f)).
    public static let bitsPerPixel: Double = 0.04
    public static let fps: Double = 30
    /// Floor: never below 1 Mbps (a small window still needs to be readable).
    public static let floorBps: Double = 1_000_000
    /// Ceiling: never above 8 Mbps for one track.
    public static let ceilingBps: Double = 8_000_000

    /// Target bitrate (bps) for a share of `pixelWidth × pixelHeight`.
    public static func bitrate(pixelWidth: Int, pixelHeight: Int) -> Double {
        let area = Double(max(0, pixelWidth)) * Double(max(0, pixelHeight))
        let raw = area * fps * bitsPerPixel
        return min(max(raw, floorBps), ceilingBps)
    }
}
