import Foundation
import AppKit
import JoeScreenKit

/// The `.clipboard`-channel pump (spec F6). NSPasteboard has NO change notification, so this polls
/// `changeCount` on the main actor and feeds observed changes to the pure, unit-tested
/// `ClipboardSyncEngine` (which decides what to transmit + suppresses echo loops). Inbound payloads
/// are written to the local pasteboard.
///
/// Security posture (DECISIONS §5.5): sync is **session-scoped, default OFF, never persisted** — the
/// user opts in per session and it resets to off next launch. Size limits + type gating live in the
/// engine. This pump only runs its poll loop while enabled.
@MainActor
final class ClipboardPump {
    private let channel: any WireDataChannel
    private let localID: ParticipantID?
    private var engine = ClipboardSyncEngine()
    private var pollTask: Task<Void, Never>?
    private var inboundTask: Task<Void, Never>?

    /// Session-scoped enable (default OFF, never persisted). Toggling on starts polling; off stops it.
    private(set) var enabled = false

    init(channel: any WireDataChannel, localID: ParticipantID?) {
        self.channel = channel
        self.localID = localID
    }

    /// Enable/disable clipboard sync for THIS session. Starts/stops the pasteboard poll loop.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            // Seed the engine at the current changeCount so we don't immediately ship whatever is
            // already on the clipboard the instant the user enables sync.
            engine = ClipboardSyncEngine(initialChangeCount: NSPasteboard.general.changeCount)
            startPolling()
            startInbound()
        } else {
            pollTask?.cancel(); pollTask = nil
            inboundTask?.cancel(); inboundTask = nil
        }
    }

    func stop() { setEnabled(false) }

    // MARK: - Outbound (poll → engine → send)

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                try? await Task.sleep(nanoseconds: 500_000_000) // 2 Hz — cheap, responsive enough
            }
        }
    }

    private func pollOnce() {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        // Read plain UTF-8 text first (the primary code use case).
        guard let text = pb.string(forType: .string), let bytes = text.data(using: .utf8) else { return }
        do {
            guard let payload = try engine.onPasteboardObserved(
                changeCount: changeCount, type: .utf8Text, bytes: bytes, sourceWindowID: nil) else { return }
            send(payload)
        } catch {
            // Oversize / disallowed → skip silently (never ship a hostile payload).
        }
    }

    private func send(_ payload: ClipboardPayload) {
        guard let sender = localID,
              let env = try? WireCodec.pack(payload, sender: sender),
              let bytes = try? WireCodec.encode(env) else { return }
        Task { try? await channel.send(bytes) }
    }

    // MARK: - Inbound (receive → engine.prepareApply → write pasteboard)

    private func startInbound() {
        inboundTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await data in self.channel.incoming() {
                guard let env = try? WireCodec.decode(data), env.kind == .clipboard,
                      env.senderID != self.localID, // ignore our own echoes
                      let payload = try? WireCodec.unpack(env, as: ClipboardPayload.self) else { continue }
                self.apply(payload)
            }
        }
    }

    private func apply(_ payload: ClipboardPayload) {
        guard payload.type == .utf8Text else { return } // v1: text only on the write side
        do {
            let bytes = try engine.prepareApply(payload) // records the digest → suppresses the echo
            if let text = String(data: bytes, encoding: .utf8) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        } catch {
            // Inbound payload violated limits — ignore.
        }
    }
}
