import Foundation
import JoeScreenKit
import JoeScreenInputMac

/// The `.input`-channel pump (spec §3.5 / F4), template-matched to `CursorPump`. Two directions:
///
///  • **Controller (outbound):** a driving participant plans intents via `InputEventPlanner` and
///    sends the resulting `InputEvent` sequence in order on the reliable/ordered `.input` channel
///    (monotonic seq per the channel policy).
///  • **Owner (inbound):** each received `InputEvent` is authorized against TRUSTED LOCAL STATE
///    (`InputAuthorizer`) and, only on `.inject`, executed via `CGEventInjector`. The authorization
///    is the security boundary (D12); the coordination-plane flags are display-only.
///
/// The runtime injection rows are HUMAN-GATED (need the kTCCServicePostEvent grant + the Phase-0(c)
/// strategy spike); everything here is buildable and the planning/authorization is Tier-1-tested.
actor InputPump {
    private let channel: any WireDataChannel
    private let localID: ParticipantID?
    private let injector: CGEventInjector
    private var seq: UInt64 = 0

    /// Owner-side trusted state + window-bounds provider, supplied by the app. Nil on a pure
    /// controller that never injects.
    private let ownerStateProvider: (@Sendable () -> InputAuthorizer.OwnerState)?
    private let boundsProvider: (@Sendable (WindowID) -> (bounds: WindowBounds, scale: Double)?)?
    private let authorizer = InputAuthorizer()

    init(
        channel: any WireDataChannel,
        localID: ParticipantID?,
        injector: CGEventInjector = CGEventInjector(),
        ownerStateProvider: (@Sendable () -> InputAuthorizer.OwnerState)? = nil,
        boundsProvider: (@Sendable (WindowID) -> (bounds: WindowBounds, scale: Double)?)? = nil
    ) {
        self.channel = channel
        self.localID = localID
        self.injector = injector
        self.ownerStateProvider = ownerStateProvider
        self.boundsProvider = boundsProvider
    }

    // MARK: - Controller (outbound)

    /// Plan an intent and send its `InputEvent` sequence in order on the input channel.
    func send(intent: InputEventPlanner.Intent, windowID: WindowID) async {
        guard let sender = localID else { return }
        for event in InputEventPlanner.plan(intent, windowID: windowID) {
            seq &+= 1
            guard let env = try? WireCodec.pack(event, sender: sender, seq: seq),
                  let bytes = try? WireCodec.encode(env) else { continue }
            try? await channel.send(bytes)
        }
    }

    /// Send a control request/release (kind 13).
    func sendControlRequest(_ action: ControlRequest.Action, windowID: WindowID) async {
        guard let sender = localID else { return }
        seq &+= 1
        let req = ControlRequest(participantID: sender, windowID: windowID, action: action)
        guard let env = try? WireCodec.pack(req, sender: sender, seq: seq),
              let bytes = try? WireCodec.encode(env) else { return }
        try? await channel.send(bytes)
    }

    // MARK: - Owner (inbound → authorize → inject)

    /// Consume inbound input, authorize each event, and inject the authorized ones. `onControlRequest`
    /// surfaces a consent prompt to the owner UI. Injection is only performed when an owner-state and
    /// bounds provider were supplied (the owner side).
    func runInbound(
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        onControlRequest: @escaping @MainActor (ControlRequest) -> Void = { _ in }
    ) async {
        for await data in channel.incoming() {
            guard let env = try? WireCodec.decode(data), let kind = env.kind else { continue }
            if env.senderID == localID { continue } // ignore our own echoes
            switch kind {
            case .inputEvent:
                guard let event = try? WireCodec.unpack(env, as: InputEvent.self),
                      event.eventKind.isKnown else { continue } // ignore unknown (tolerant decode)
                await authorizeAndInject(event: event, sender: env.senderID, now: now())
            case .controlRequest:
                if let req = try? WireCodec.unpack(env, as: ControlRequest.self) {
                    await MainActor.run { onControlRequest(req) }
                }
            default:
                continue
            }
        }
    }

    private func authorizeAndInject(event: InputEvent, sender: ParticipantID, now: Double) async {
        guard let ownerStateProvider, let boundsProvider else { return } // controller-only pump
        let state = ownerStateProvider()
        // The transport already authenticated the delivering peer as `sender` (the SFU binds
        // data-channel messages to their publisher), so messageSender == transportPeer here.
        let decision = authorizer.authorize(
            event: event, messageSender: sender, transportPeer: sender, state: state, now: now)
        guard decision == .inject, let resolved = boundsProvider(event.windowID) else { return }
        injector.inject(event, into: resolved.bounds, backingScale: resolved.scale)
    }
}
