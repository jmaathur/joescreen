import Foundation

/// Preflights the CORRECT TCC services for input injection (spec §2.3 / D12 / R26).
///
/// The load-bearing distinction: synthesizing input via `CGEvent.post` is gated by
/// **`kTCCServicePostEvent`** (surfaced under Accessibility in System Settings), which is a
/// SEPARATE service from **`kTCCServiceAccessibility`** — the one `AXIsProcessTrusted()` checks and
/// the AX APIs use. An app can hold one and not the other. So we must NOT preflight injection with
/// `AXIsProcessTrusted()` (it checks the wrong service and reports misleading state). We also may
/// need `kTCCServiceAccessibility` for AX focus-assist, so both are surfaced as distinct rows.
///
/// These grants are UNAVAILABLE to sandboxed apps — which is why the Mac app ships as a
/// non-sandboxed Developer-ID build (D6). This type only inspects/represents grant state; the
/// actual TCC probing is macOS-only and wrapped below.
public struct InjectionPermissions: Sendable {

    /// The two independent grants this app may need. They are tracked and surfaced separately.
    public struct Status: Sendable, Equatable {
        /// kTCCServicePostEvent — REQUIRED to synthesize mouse/keyboard input. This is the one that
        /// actually gates injection.
        public var canPostEvents: Bool
        /// kTCCServiceAccessibility — needed only for AX focus-assist (window raise) on stubborn
        /// targets. NOT sufficient for injection on its own.
        public var hasAccessibility: Bool
        public init(canPostEvents: Bool, hasAccessibility: Bool) {
            self.canPostEvents = canPostEvents
            self.hasAccessibility = hasAccessibility
        }
        /// Injection is possible iff PostEvent is granted, regardless of the AX grant.
        public var canInject: Bool { canPostEvents }
    }

    public init() {}

    #if os(macOS)
    /// Probe the live grant state. `kTCCServicePostEvent` is checked via `CGPreflightPostEventAccess()`
    /// (do NOT use AXIsProcessTrusted here — wrong service). AX is checked via `AXIsProcessTrusted()`.
    public func current() -> Status {
        let post = _cgPreflightPostEventAccess()
        let ax = _axIsProcessTrusted()
        return Status(canPostEvents: post, hasAccessibility: ax)
    }

    /// Request the PostEvent grant (prompts once; the user must add the app in System Settings).
    @discardableResult
    public func requestPostEventAccess() -> Bool {
        _cgRequestPostEventAccess()
    }
    #endif
}

// MARK: - macOS TCC shims (wrapped so the pure API above compiles on any host)

#if os(macOS)
import ApplicationServices
import CoreGraphics

/// `CGPreflightPostEventAccess()` (macOS 10.15+) checks kTCCServicePostEvent WITHOUT prompting.
@inline(__always) private func _cgPreflightPostEventAccess() -> Bool {
    CGPreflightPostEventAccess()
}
/// `CGRequestPostEventAccess()` prompts for kTCCServicePostEvent.
@inline(__always) private func _cgRequestPostEventAccess() -> Bool {
    CGRequestPostEventAccess()
}
/// `AXIsProcessTrusted()` checks kTCCServiceAccessibility — the WRONG service for injection, used
/// here ONLY for the AX focus-assist row.
@inline(__always) private func _axIsProcessTrusted() -> Bool {
    AXIsProcessTrusted()
}
#endif
