import Foundation

/// Generates the monotonic per-author `authorSeq` for outbound `DrawOp`s (F9). Each author's ops
/// must strictly increase so `DrawModel.apply` accepts them in order and rejects replays. Pure +
/// unit-tested; the `DrawPump` owns one instance for the local author.
public struct DrawAuthorSequencer: Sendable {
    private var next: UInt64

    /// - Parameter start: the first seq to hand out (default 1; 0 is reserved as "never sent").
    public init(start: UInt64 = 1) { self.next = max(1, start) }

    /// The next monotonic sequence for an outbound op.
    public mutating func advance() -> UInt64 {
        let s = next
        next &+= 1
        return s
    }

    /// The seq that would be handed out next (without advancing) — for tests / diagnostics.
    public var peek: UInt64 { next }
}
