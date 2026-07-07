import Foundation
import JoeScreenKit

/// The cursor-channel pump (spec §3.8 / M6). Outbound: coalesce cursor moves to the latest and emit
/// at ~60 fps (never faster) on the unreliable/unordered `cursor` channel. Inbound: latest-wins —
/// drop arrivals with an older timestamp than the last one seen for that (sender, window).
///
/// The pure coalescing/latest-wins logic is in `CursorCoalescer` (unit-tested, JoeScreenKit-free
/// here in the app but mirrored by a testable type). This actor is the runtime glue over
/// `WireDataChannel`.
actor CursorPump {
    private let channel: any WireDataChannel
    private let localID: ParticipantID?

    /// Latest pending outbound move per window (coalesced). Sent on the next tick.
    private var pendingOutbound: [WindowID: CursorMove] = [:]
    private var senderTimestamps: [Key: Double] = [:]
    private var outboundTask: Task<Void, Never>?

    private struct Key: Hashable { let sender: ParticipantID; let window: WindowID }

    init(channel: any WireDataChannel, localID: ParticipantID?) {
        self.channel = channel
        self.localID = localID
    }

    // MARK: - Outbound (coalesce → ~60fps)

    /// Record the local cursor position over a remote window; coalesced and flushed at ~60 fps.
    func sendLocalCursor(windowID: WindowID, point: NormalizedPoint, timestamp: Double) {
        guard let localID else { return }
        pendingOutbound[windowID] = CursorMove(windowID: windowID, point: point, timestamp: timestamp)
        startOutboundLoopIfNeeded(sender: localID)
    }

    private func startOutboundLoopIfNeeded(sender: ParticipantID) {
        guard outboundTask == nil else { return }
        outboundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.flushOutbound(sender: sender)
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60 fps
                if await self?.pendingIsEmpty() == true {
                    await self?.stopOutbound()
                    return
                }
            }
        }
    }

    private func pendingIsEmpty() -> Bool { pendingOutbound.isEmpty }
    private func stopOutbound() { outboundTask = nil }

    private func flushOutbound(sender: ParticipantID) async {
        let moves = pendingOutbound
        pendingOutbound.removeAll()
        for (_, move) in moves {
            guard let env = try? WireCodec.pack(move, sender: sender),
                  let bytes = try? WireCodec.encode(env) else { continue }
            try? await channel.send(bytes)
        }
    }

    // MARK: - Inbound (latest-wins)

    /// Consume inbound cursor moves, invoking `onCursor` for each accepted (non-stale) one.
    func runInbound(_ onCursor: @escaping @MainActor (WindowID, ParticipantID, NormalizedPoint) -> Void) async {
        for await data in channel.incoming() {
            guard let env = try? WireCodec.decode(data),
                  env.kind == .cursorMove,
                  let move = try? WireCodec.unpack(env, as: CursorMove.self) else { continue }
            // Ignore our own echoes.
            if env.senderID == localID { continue }
            let key = Key(sender: env.senderID, window: move.windowID)
            // Latest-wins: drop stale timestamps.
            if let last = senderTimestamps[key], move.timestamp <= last { continue }
            senderTimestamps[key] = move.timestamp
            let sender = env.senderID
            await MainActor.run { onCursor(move.windowID, sender, move.point) }
        }
    }
}
