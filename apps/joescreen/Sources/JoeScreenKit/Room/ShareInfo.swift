import Foundation

/// Descriptive metadata about one shared surface, mirrored on the control plane so receivers can
/// title a viewer window and size it aspect-true before the first video frame arrives (M9), and so
/// M11 display shares carry their kind. Everything except `kind` is optional and decoded with
/// `decodeIfPresent`, so an old peer that predates a field (or the whole struct) keeps decoding —
/// the additive-only wire rule (§2).
///
/// It is ADVISORY UI metadata, never an authorization input (the trust model in `RoomModel`): a
/// peer lying about a title or pixel size gains nothing. Pixel dimensions seed the receiver's
/// aspect ratio; the authoritative dimensions still arrive via the track's own dimension updates.
public struct ShareInfo: Codable, Sendable, Equatable {
    /// Whether this share is a single window or a whole display.
    public var kind: ShareKind
    /// The window/display title at share time (e.g. "main.swift — MyApp"), for the viewer title bar.
    public var title: String?
    /// The owning application's name (e.g. "Xcode"), for the viewer chrome.
    public var appName: String?
    /// Source width in PIXELS (Retina-native) at share time — seeds the receiver's aspect ratio.
    public var sourcePixelWidth: Int?
    /// Source height in PIXELS (Retina-native) at share time — seeds the receiver's aspect ratio.
    public var sourcePixelHeight: Int?

    public init(
        kind: ShareKind,
        title: String? = nil,
        appName: String? = nil,
        sourcePixelWidth: Int? = nil,
        sourcePixelHeight: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.appName = appName
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
    }

    // Explicit keys keep the wire JSON stable regardless of property order.
    enum CodingKeys: String, CodingKey {
        case kind, title, appName, sourcePixelWidth, sourcePixelHeight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `kind` predates any future field and is required; default to `.window` only if a truly
        // ancient peer omitted it (defensive — current encoders always write it).
        self.kind = try c.decodeIfPresent(ShareKind.self, forKey: .kind) ?? .window
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName)
        self.sourcePixelWidth = try c.decodeIfPresent(Int.self, forKey: .sourcePixelWidth)
        self.sourcePixelHeight = try c.decodeIfPresent(Int.self, forKey: .sourcePixelHeight)
    }

    /// The source aspect ratio (width / height) if both pixel dimensions are known and positive;
    /// `nil` otherwise (the receiver falls back to a default until real dimensions arrive).
    public var sourceAspectRatio: Double? {
        guard let w = sourcePixelWidth, let h = sourcePixelHeight, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }
}
