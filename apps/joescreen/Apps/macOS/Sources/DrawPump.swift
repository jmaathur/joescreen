import Foundation
import JoeScreenKit

/// The `.draw`-channel pump (spec F9), template-matched to `CursorPump`. Outbound: publish the local
/// author's `DrawOp`/`DrawClear`/`DrawUndo` with a monotonic `authorSeq` (from `DrawAuthorSequencer`)
/// on the reliable/ordered-per-author draw channel. Inbound: decode + apply to the shared `DrawModel`
/// (which is convergent by construction) and notify the overlay. Late joiners get the current ink via
/// the RoomSnapshot path (the host includes DrawModel), so no separate replay is needed here.
actor DrawPump {
    private let channel: any WireDataChannel
    private let localID: ParticipantID?
    private var seq: UInt64 = 0 // envelope seq (the reliable channel requires monotonic per-sender)

    init(channel: any WireDataChannel, localID: ParticipantID?) {
        self.channel = channel
        self.localID = localID
    }

    // MARK: - Outbound (the caller assigns the authorSeq so the local optimistic apply matches)

    /// Publish a pre-built draw payload (DrawOp/DrawClear/DrawUndo) on the draw channel.
    func send<M: WireMessage>(_ payload: M) async {
        guard let sender = localID else { return }
        seq &+= 1
        guard let env = try? WireCodec.pack(payload, sender: sender, seq: seq),
              let bytes = try? WireCodec.encode(env) else { return }
        try? await channel.send(bytes)
    }

    // MARK: - Inbound (apply → notify)

    /// Consume inbound draw messages, apply them to the DrawModel via `mutate`, and notify `onChange`.
    /// Our OWN echoes are applied too (idempotent under the authorSeq monotonicity check) so the local
    /// author sees a single source of truth; the sequencer guarantees our ops never regress.
    func runInbound(
        mutate: @escaping @MainActor (_ apply: (inout DrawModel) -> Void) -> Void,
        onChange: @escaping @MainActor (WindowID) -> Void
    ) async {
        for await data in channel.incoming() {
            guard let env = try? WireCodec.decode(data), let kind = env.kind else { continue }
            switch kind {
            case .drawOp:
                guard let op = try? WireCodec.unpack(env, as: DrawOp.self) else { continue }
                await MainActor.run { mutate { $0.apply(op) }; onChange(op.windowID) }
            case .drawClear:
                guard let clear = try? WireCodec.unpack(env, as: DrawClear.self) else { continue }
                await MainActor.run { mutate { $0.apply(clear) }; onChange(clear.windowID) }
            case .drawUndo:
                guard let undo = try? WireCodec.unpack(env, as: DrawUndo.self) else { continue }
                await MainActor.run { mutate { $0.apply(undo) }; onChange(undo.windowID) }
            default:
                continue
            }
        }
    }
}
