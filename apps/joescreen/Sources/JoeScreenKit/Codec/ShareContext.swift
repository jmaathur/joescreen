import Foundation

/// The set of shares one host is publishing, and the STRUCTURAL codec that set implies (spec D5 /
/// M11). Pure logic so "including the pending share" math is unit-tested and the codec-ordering bug
/// (latent #3 — publish options snapshotted before the context updated) is fixed structurally.
///
/// D5 structural rule: a SINGLE window share (and no display) is VP9 for small-text legibility;
/// ≥2 windows OR any display share forces H.264 for ALL share tracks. This reducer is the single
/// place that rule lives; `AppModel` computes the context INCLUDING the share it is about to publish
/// and pushes it to the transport BEFORE publishing, so the new track gets the right codec.
public struct ShareContext: Sendable, Equatable {
    public private(set) var windowShareCount: Int
    public private(set) var displayShareCount: Int

    public init(windowShareCount: Int = 0, displayShareCount: Int = 0) {
        self.windowShareCount = max(0, windowShareCount)
        self.displayShareCount = max(0, displayShareCount)
    }

    /// Total share tracks this host publishes.
    public var totalShareCount: Int { windowShareCount + displayShareCount }

    /// Whether any whole-display share is present.
    public var wholeDisplay: Bool { displayShareCount > 0 }

    /// The structural codec this context implies (D5). VP9 only for exactly one window + no display.
    public var structuralCodec: VideoCodec {
        (windowShareCount == 1 && displayShareCount == 0) ? .vp9 : .h264
    }

    /// The context AFTER adding one share of `kind` — used to compute publish options that reflect
    /// the pending share BEFORE it is published (the ordering fix).
    public func adding(_ kind: ShareKind) -> ShareContext {
        switch kind {
        case .window:  return ShareContext(windowShareCount: windowShareCount + 1, displayShareCount: displayShareCount)
        case .display: return ShareContext(windowShareCount: windowShareCount, displayShareCount: displayShareCount + 1)
        }
    }

    /// The context after removing one share of `kind` (clamped at 0).
    public func removing(_ kind: ShareKind) -> ShareContext {
        switch kind {
        case .window:  return ShareContext(windowShareCount: windowShareCount - 1, displayShareCount: displayShareCount)
        case .display: return ShareContext(windowShareCount: windowShareCount, displayShareCount: displayShareCount - 1)
        }
    }

    /// Whether flipping from `self` to `other` changes the STRUCTURAL codec (i.e. a live renegotiation
    /// is required for existing share tracks — M11 structural renegotiation).
    public func structuralCodecChanged(to other: ShareContext) -> Bool {
        structuralCodec != other.structuralCodec
    }
}
