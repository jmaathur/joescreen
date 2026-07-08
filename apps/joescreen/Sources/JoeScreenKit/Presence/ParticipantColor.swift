import Foundation

/// Deterministic participant color assignment (spec §3.3: each remote window is drawn with the
/// sharer's assigned color as its border; cursors/ink reuse the same color).
///
/// Every peer must compute the SAME color for a given participant with zero negotiation, so the
/// mapping is a pure function of the stable `ParticipantID` bytes:
///
///     UUID bytes → FNV-1a 64 (process-independent; Swift's `Hasher` is seeded per-process and
///     MUST NOT be used here) → index into a fixed 12-hue palette → HSV→RGB at fixed S/V.
///
/// Two participants CAN collide once a session exceeds 12 people (birthday bound well before
/// that); that's acceptable — color is a recognition aid, identity always comes from the roster.
/// Caseless enum = pure namespace, trivially Sendable.
public enum ParticipantColor {

    /// Palette hues (degrees). 12 hues spaced 30° apart, ordered so hash-adjacent indices are
    /// far apart on the wheel — small rosters get maximally distinct colors even if their hashes
    /// land near each other.
    public static let paletteHues: [Double] = [
        210, // blue
        30,  // orange
        150, // spring green
        330, // pink
        90,  // chartreuse
        270, // purple
        0,   // red
        180, // cyan
        60,  // yellow
        300, // magenta
        120, // green
        240, // indigo
    ]

    /// Saturation/value chosen to read as a chrome accent on both light and dark surfaces.
    public static let saturation: Double = 0.72
    public static let value: Double = 0.92

    /// Stable palette index for a participant. Exposed for tests and for UIs that want the
    /// index (e.g. to pick a matching text label color).
    public static func hueIndex(for id: ParticipantID) -> Int {
        Int(stableHash(id) % UInt64(paletteHues.count))
    }

    /// The participant's assigned color, alpha 1. Reuses the wire `RGBAColor` so draw ink
    /// defaults (`DrawOp.color`) and chrome borders share one representation.
    public static func color(for id: ParticipantID) -> RGBAColor {
        let (r, g, b) = components(for: id)
        return RGBAColor(r: r, g: g, b: b, a: 1)
    }

    /// Raw RGB components in [0, 1] for callers that don't want the wire type.
    public static func components(for id: ParticipantID) -> (r: Double, g: Double, b: Double) {
        rgb(hueDegrees: paletteHues[hueIndex(for: id)], saturation: saturation, value: value)
    }

    // MARK: - Internals

    /// FNV-1a 64-bit over the UUID's 16 raw bytes. Deterministic across processes, platforms,
    /// and app launches — the property the per-process-seeded `Hasher` lacks.
    private static func stableHash(_ id: ParticipantID) -> UInt64 {
        let u = id.uuid
        let bytes: [UInt8] = [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3 // FNV prime
        }
        return hash
    }

    /// Standard HSV→RGB. `hueDegrees` may be any real; it's normalized into [0, 360).
    private static func rgb(
        hueDegrees: Double, saturation: Double, value: Double
    ) -> (r: Double, g: Double, b: Double) {
        let hue = (hueDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let c = value * saturation
        let x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r1, g1, b1): (Double, Double, Double)
        switch hue {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }
}
