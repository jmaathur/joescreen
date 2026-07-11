import Foundation
import JoeScreenKit

/// Detects macOS **Secure Event Input** (spec R8). When any app enables secure input (a focused
/// password field, some terminals), the window server BLOCKS synthesized events from other processes
/// — so a remote driver's injection silently does nothing. This wraps the macOS
/// `IsSecureEventInputEnabled()` probe; the pure banner DECISION lives in
/// `JoeScreenKit.SecureInputBanner` (machine-gate tested). Debounced polling belongs to the app.
public struct SecureInputDetector: Sendable {
    public init() {}

    #if os(macOS)
    /// Live probe of Secure Event Input. `true` ⇒ injected events are being blocked by the OS.
    public func isSecureInputActive() -> Bool {
        _isSecureEventInputEnabled()
    }
    #endif

    /// The banner to show, given the live secure-input flag and whether a peer is driving.
    public func banner(secureInputActive: Bool, someoneIsDriving: Bool) -> SecureInputBanner {
        SecureInputBanner.decide(secureInputActive: secureInputActive, someoneIsDriving: someoneIsDriving)
    }
}

#if os(macOS)
import Carbon.HIToolbox

/// `IsSecureEventInputEnabled()` (Carbon HIToolbox) — the OS-level flag for secure input. Wrapped so
/// the pure API above compiles on any host.
@inline(__always) private func _isSecureEventInputEnabled() -> Bool {
    IsSecureEventInputEnabled()
}
#endif
