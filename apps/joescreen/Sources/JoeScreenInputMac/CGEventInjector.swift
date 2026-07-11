import Foundation
import JoeScreenKit

/// How synthesized events reach the target (spec §3.5 / R26 / Phase-0(c)). The DEFAULT is `hidTap`
/// (posts to the HID event tap, moving the owner's physical cursor — the CoScreen-equivalent, and
/// the only strategy verified to reliably reach an unfocused window). `postToPid` is unreliable to
/// unfocused windows (R26); `hybrid` tries postToPid then falls back. The strategy is a runtime
/// switch so the **Phase-0(c) injection spike** (a HUMAN step on the ledger) later flips a value
/// rather than restructuring code.
public enum InjectionStrategy: String, Sendable, Equatable, CaseIterable {
    case hidTap        // CGEvent.post(tap: .cghidEventTap) — moves the physical cursor (default)
    case postToPid     // CGEvent.postToPid — unreliable to unfocused windows (R26)
    case hybrid        // postToPid then hidTap fallback
}

/// Injects a remote peer's authorized `InputEvent` as a real `CGEvent` on the owner Mac (F4). This
/// is the most consequential runtime seam — it only runs AFTER `InputAuthorizer` returns `.inject`
/// and requires the `kTCCServicePostEvent` grant (a human step). The coordinate math is the pure,
/// unit-tested `CoordinateMapper` (the security clamp lives there); this class does the CGEvent
/// synthesis. Strategy is runtime-switchable (default `hidTap`) pending the Phase-0(c) spike.
public struct CGEventInjector: Sendable {
    public var strategy: InjectionStrategy

    public init(strategy: InjectionStrategy = .hidTap) {
        self.strategy = strategy
    }

    #if os(macOS)
    /// Inject one authorized event. `bounds` is the OWNER's real window bounds (CG top-left space);
    /// `backingScale` is the owner display's scale. Returns whether a CGEvent was posted. The caller
    /// MUST have passed `InputAuthorizer.authorize(...) == .inject` first — this does NO authorization.
    @discardableResult
    public func inject(_ event: InputEvent, into bounds: WindowBounds, backingScale: Double, ownerPID: Int32? = nil) -> Bool {
        let mapper = CoordinateMapper()
        let mapped = event.point.map { mapper.toGlobalCGPoint($0, in: bounds, backingScale: backingScale) }
        return CGEventSynth.post(event: event, at: mapped, strategy: strategy, ownerPID: ownerPID)
    }
    #endif
}
