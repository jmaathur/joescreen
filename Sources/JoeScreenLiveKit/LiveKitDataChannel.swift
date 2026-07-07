import Foundation
import LiveKit
import JoeScreenKit

/// A `WireDataChannel` (JoeScreenKit seam) over LiveKit data-publish, one per `DataChannel`.
///
/// Mapping (§3):
///   • topic = `DataChannel.rawValue` — so the receiver demuxes by topic back to the right channel,
///   • `reliable` = derived from `ChannelPolicy.policy(for:).reliability` (NEVER hand-picked;
///     LiveKit's `reliable` defaults to FALSE — landmine #2),
///   • outbound payloads >14 KB are framed by `Chunker` (LiveKit's ~15 KB per-message cap — NOT the
///     messenger's 256 KB), and reassembled on receipt.
///
/// Ordering note: LiveKit's reliable data channel preserves send order; the unreliable (cursor)
/// channel is latest-wins and never chunked (reassembly needs reliable/ordered delivery). So we only
/// chunk on reliable channels; an oversize payload on the cursor channel is dropped with a log
/// (cursor payloads are tiny by construction, so this never fires in practice).
final class LiveKitDataChannel: WireDataChannel, @unchecked Sendable {
    let channel: DataChannel
    private let policy: ChannelPolicy
    private let room: Room
    /// Chunk budget: keep the ENCODED chunk under LiveKit's ~15 KB cap. Chunker's default (10 KB raw)
    /// leaves room for base64 + JSON overhead (verified by ChunkerTests).
    private let maxChunkBytes = Chunker.defaultMaxChunkBytes

    // Inbound plumbing. The delegate pushes raw topic payloads via `receive`; this reassembles
    // chunked payloads and yields whole Envelopes' bytes to `incoming()`'s stream.
    private let lock = NSLock()
    private var reassembler = Chunker.Reassembler()
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    init(channel: DataChannel, room: Room) {
        self.channel = channel
        self.policy = ChannelPolicy.policy(for: channel)
        self.room = room
    }

    // MARK: - Outbound

    func send(_ payload: Data) async throws {
        let reliable = policy.reliability == .reliable
        let topic = channel.rawValue

        // Unreliable (cursor): never chunk; drop-if-oversize (shouldn't happen for cursor moves).
        guard reliable else {
            if payload.count > maxChunkBytes {
                // Cursor payloads are tiny; an oversize one is a bug, not a real case. Drop it rather
                // than fragment on a lossy channel where reassembly can't be guaranteed.
                return
            }
            try await publish(payload, topic: topic, reliable: false)
            return
        }

        // Reliable: frame anything over the budget, else send as one chunk (count == 1) so the
        // receiver's reassembler path is uniform.
        let chunks = Chunker.split(payload, maxChunkBytes: maxChunkBytes)
        for chunk in chunks {
            let wire = try Chunker.encode(chunk)
            try await publish(wire, topic: topic, reliable: true)
        }
    }

    private func publish(_ data: Data, topic: String, reliable: Bool) async throws {
        try await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: topic, reliable: reliable))
    }

    // MARK: - Inbound

    func incoming() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Called by the room delegate for every data packet on THIS channel's topic. On reliable
    /// channels the bytes are a `Chunker.Chunk`; reassembled whole payloads are yielded. On the
    /// unreliable channel the bytes are the whole payload (never chunked).
    func receive(_ data: Data) {
        if policy.reliability == .reliable {
            do {
                let chunk = try Chunker.decode(data)
                lock.lock()
                let assembled = try? reassembler.offer(chunk)
                let conts = Array(continuations.values)
                lock.unlock()
                if let whole = assembled {
                    for c in conts { c.yield(whole) }
                }
            } catch {
                // A non-chunk payload on a reliable topic (shouldn't happen since we always frame):
                // pass it through raw rather than dropping.
                lock.lock(); let conts = Array(continuations.values); lock.unlock()
                for c in conts { c.yield(data) }
            }
        } else {
            lock.lock(); let conts = Array(continuations.values); lock.unlock()
            for c in conts { c.yield(data) }
        }
    }

    func finish() {
        lock.lock()
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }
}
