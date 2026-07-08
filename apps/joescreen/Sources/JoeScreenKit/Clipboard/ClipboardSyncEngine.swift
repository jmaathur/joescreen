import Foundation

/// Platform-neutral clipboard sync core (spec F6). NSPasteboard has NO change notification, so the
/// platform monitor polls `changeCount` and feeds observed changes here; this engine decides what
/// to transmit and how to apply remote clipboards without echo loops. Kept pure so it's unit-tested
/// without AppKit.
///
/// Primary use case is CODE: plain UTF-8 text with EXACT whitespace/newlines preserved comes first;
/// RTF/image are secondary and size-limited.
public struct ClipboardSyncEngine: Sendable {

    /// Limits to avoid shipping huge/hostile payloads over the reliable channel.
    public struct Limits: Sendable {
        public var maxTextBytes: Int
        public var maxRTFBytes: Int
        public var maxImageBytes: Int
        public var allowImage: Bool
        public init(maxTextBytes: Int = 1 << 20, maxRTFBytes: Int = 4 << 20,
                    maxImageBytes: Int = 16 << 20, allowImage: Bool = true) {
            self.maxTextBytes = maxTextBytes; self.maxRTFBytes = maxRTFBytes
            self.maxImageBytes = maxImageBytes; self.allowImage = allowImage
        }
    }

    public enum RejectReason: Error, Equatable {
        case tooLarge(ClipboardType, bytes: Int, limit: Int)
        case typeNotAllowed(ClipboardType)
    }

    private let limits: Limits
    /// The changeCount we last observed. Only a STRICT increase triggers a send.
    private var lastObservedChangeCount: Int
    /// A hash of the last payload WE applied from a remote, so re-observing our own write (which
    /// bumps changeCount) does not echo it back out.
    private var lastAppliedDigest: Int?

    public init(limits: Limits = Limits(), initialChangeCount: Int = 0) {
        self.limits = limits
        self.lastObservedChangeCount = initialChangeCount
    }

    /// Called by the platform monitor when it polls the pasteboard.
    /// Returns a payload to transmit, or `nil` if nothing should be sent (no change, or it was our
    /// own applied write echoing back). Throws on limit/type violations.
    public mutating func onPasteboardObserved(
        changeCount: Int,
        type: ClipboardType,
        bytes: Data,
        sourceWindowID: WindowID?
    ) throws -> ClipboardPayload? {
        // No strict increase → identical clipboard → no traffic.
        guard changeCount > lastObservedChangeCount else { return nil }
        lastObservedChangeCount = changeCount

        // Echo suppression: if this exactly matches what we just applied from a remote, swallow it.
        let digest = Self.digest(type: type, bytes: bytes)
        if digest == lastAppliedDigest {
            lastAppliedDigest = nil // one-shot suppression
            return nil
        }

        try enforce(type: type, bytes: bytes)
        return ClipboardPayload(type: type, bytes: bytes, sourceWindowID: sourceWindowID)
    }

    /// Called when a remote clipboard payload arrives, BEFORE writing it to the local pasteboard.
    /// Records the digest so the subsequent self-write (which bumps changeCount) is suppressed.
    /// Returns the bytes to write, or throws if the incoming payload violates limits.
    public mutating func prepareApply(_ payload: ClipboardPayload) throws -> Data {
        try enforce(type: payload.type, bytes: payload.bytes)
        lastAppliedDigest = Self.digest(type: payload.type, bytes: payload.bytes)
        return payload.bytes
    }

    private func enforce(type: ClipboardType, bytes: Data) throws {
        switch type {
        case .utf8Text:
            guard bytes.count <= limits.maxTextBytes else {
                throw RejectReason.tooLarge(.utf8Text, bytes: bytes.count, limit: limits.maxTextBytes)
            }
        case .rtf:
            guard bytes.count <= limits.maxRTFBytes else {
                throw RejectReason.tooLarge(.rtf, bytes: bytes.count, limit: limits.maxRTFBytes)
            }
        case .image:
            guard limits.allowImage else { throw RejectReason.typeNotAllowed(.image) }
            guard bytes.count <= limits.maxImageBytes else {
                throw RejectReason.tooLarge(.image, bytes: bytes.count, limit: limits.maxImageBytes)
            }
        }
    }

    private static func digest(type: ClipboardType, bytes: Data) -> Int {
        var h = Hasher()
        h.combine(type)
        h.combine(bytes)
        return h.finalize()
    }
}
