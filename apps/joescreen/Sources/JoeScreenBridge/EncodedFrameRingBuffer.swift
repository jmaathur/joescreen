import Foundation

/// A bounded ring buffer for handing ENCODED video frames from the iOS broadcast extension to the
/// host app across an App Group (spec §3.3 / D11 / R7). The extension runs under a ~50 MB jetsam
/// ceiling and MUST NOT queue raw pixel buffers; it hands small encoded frames here, and on
/// overflow drops the OLDEST frame rather than blocking its serial `processSampleBuffer` callback
/// (blocking the extension would stall or kill it).
///
/// This in-memory model is the unit-testable core; the production shared-memory/file-mapped App
/// Group implementation wraps the same semantics. No LiveKit/GroupActivities imports (the extension
/// must link this under budget).
public struct EncodedFrameRingBuffer: Sendable {

    public struct Frame: Sendable, Equatable {
        /// Encoded bytes (e.g. an H.264 access unit / annex-B or a CMSampleBuffer's data blob).
        public var data: Data
        /// Presentation timestamp (seconds).
        public var pts: Double
        /// True if this is a keyframe (IDR) — the reader may need it to start decoding.
        public var isKeyframe: Bool
        public init(data: Data, pts: Double, isKeyframe: Bool) {
            self.data = data; self.pts = pts; self.isKeyframe = isKeyframe
        }
    }

    /// Overflow policy stats, useful for surfacing "we're dropping frames" backpressure signals.
    public private(set) var droppedCount: Int = 0

    private var storage: [Frame] = []
    private let capacity: Int
    /// Soft byte budget; if exceeded, drop oldest until under budget (keeps RSS bounded).
    private let maxBytes: Int
    private var currentBytes: Int = 0

    public init(capacity: Int = 8, maxBytes: Int = 4 << 20) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.maxBytes = maxBytes
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Write a frame. Never blocks: on capacity/byte overflow, drops oldest frames first.
    public mutating func write(_ frame: Frame) {
        storage.append(frame)
        currentBytes += frame.data.count
        while storage.count > capacity || (currentBytes > maxBytes && storage.count > 1) {
            let removed = storage.removeFirst()
            currentBytes -= removed.data.count
            droppedCount += 1
        }
    }

    /// Read the oldest available frame (FIFO), removing it. Returns nil if empty.
    public mutating func read() -> Frame? {
        guard !storage.isEmpty else { return nil }
        let f = storage.removeFirst()
        currentBytes -= f.data.count
        return f
    }

    /// Drain up to `max` frames (reader catch-up).
    public mutating func drain(max: Int = .max) -> [Frame] {
        var out: [Frame] = []
        while out.count < max, let f = read() { out.append(f) }
        return out
    }

    public var byteFootprint: Int { currentBytes }
}
