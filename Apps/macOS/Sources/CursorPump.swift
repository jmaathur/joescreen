import Foundation
import JoeScreenKit

/// The cursor-channel pump (spec §3.8 / M6). Outbound: coalesce cursor moves to the latest per
/// window (via the unit-tested `CursorCoalescer`) and emit at ~60 fps on the unreliable/unordered
/// `cursor` channel. Inbound: latest-wins — drop arrivals older than the last seen for that
/// (sender, window). This actor is the runtime glue over `WireDataChannel`; the pure coalescing +
/// latest-wins logic lives in `CursorCoalescer` (JoeScreenKit, unit-tested).
actor CursorPump {
    private let channel: any WireDataChannel
    private let localID: ParticipantID?
    private var coalescer = CursorCoalescer()
    private var outboundTask: Task<Void, Never>?

    init(channel: any WireDataChannel, localID: ParticipantID?) {
        self.channel = channel
        self.localID = localID
    }

    // MARK: - Outbound (coalesce → ~60fps)

    /// Record the local cursor position over a remote window; coalesced and flushed at ~60 fps.
    func sendLocalCursor(windowID: WindowID, point: NormalizedPoint, timestamp: Double) {
        guard localID != nil else { return }
        coalescer.offerOutbound(CursorMove(windowID: windowID, point: point, timestamp: timestamp))
        startOutboundLoopIfNeeded()
    }

    private func startOutboundLoopIfNeeded() {
        guard outboundTask == nil, let sender = localID else { return }
        outboundTask = Task { [weak self] in
            while !Task.isCancelled {
                let done = await self?.flushOnce(sender: sender) ?? true
                if done { await self?.clearOutboundTask(); return }
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60 fps
            }
        }
    }

    /// Flush one tick's coalesced moves. Returns true when nothing remains (loop can stop).
    private func flushOnce(sender: ParticipantID) async -> Bool {
        let moves = coalescer.flushOutbound()
        for move in moves {
            guard let env = try? WireCodec.pack(move, sender: sender),
                  let bytes = try? WireCodec.encode(env) else { continue }
            try? await channel.send(bytes)
        }
        return !coalescer.hasPending
    }

    private func clearOutboundTask() { outboundTask = nil }

    // MARK: - Inbound (latest-wins)

    /// Consume inbound cursor moves, invoking `onCursor` for each accepted (non-stale) one.
    func runInbound(_ onCursor: @escaping @MainActor (WindowID, ParticipantID, NormalizedPoint) -> Void) async {
        for await data in channel.incoming() {
            guard let env = try? WireCodec.decode(data),
                  env.kind == .cursorMove,
                  let move = try? WireCodec.unpack(env, as: CursorMove.self) else { continue }
            if env.senderID == localID { continue } // ignore our own echoes
            guard coalescer.acceptInbound(sender: env.senderID, move: move) else { continue }
            let sender = env.senderID
            await MainActor.run { onCursor(move.windowID, sender, move.point) }
        }
    }
}
