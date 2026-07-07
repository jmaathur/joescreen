import Foundation
import ScreenCaptureKit

/// Wraps `SCContentSharingPicker` (the system window picker, D10 primary path) and resolves the
/// user's choice to an `SCWindow` for `WindowCaptureService`. The picker only offers the mode we
/// enable (single window) and its UI appears only when marked active.
@available(macOS 14.0, *)
final class SharePicker: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    static let shared = SharePicker()

    /// Completion delivers the chosen window's `CGWindowID` (a Sendable value) rather than the
    /// non-Sendable `SCWindow`; the caller re-resolves the SCWindow on its own actor. This keeps the
    /// non-Sendable object off the actor-crossing path.
    private let lock = NSLock()
    private var completion: ((CGWindowID) -> Void)?
    private var isObserving = false

    /// Present the picker; `onPick` fires with the chosen window's CGWindowID (single-window mode).
    func present(onPick: @escaping (CGWindowID) -> Void) {
        lock.lock(); completion = onPick; lock.unlock()
        let picker = SCContentSharingPicker.shared
        if !isObserving {
            picker.add(self)
            isObserving = true
        }
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        picker.configuration = config
        picker.isActive = true
        picker.present()
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        // Resolve the chosen window's CGWindowID synchronously from the filter (macOS 15.2+ exposes
        // includedWindows directly). We extract the plain UInt32 ID here — no non-Sendable object
        // crosses the actor boundary.
        let windowID = Self.cgWindowID(from: filter)
        guard let windowID else { return }
        lock.lock(); let done = completion; completion = nil; lock.unlock()
        if let done {
            DispatchQueue.main.async { done(windowID) }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        lock.lock(); completion = nil; lock.unlock()
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        lock.lock(); completion = nil; lock.unlock()
    }

    /// Extract the chosen window's CGWindowID from the filter. On macOS 15.2+ `includedWindows`
    /// gives it directly; that's our deployment reality (dev Mac is 15.x). Returns nil if none.
    private static func cgWindowID(from filter: SCContentFilter) -> CGWindowID? {
        if #available(macOS 15.2, *) {
            return filter.includedWindows.first?.windowID
        }
        // On 14.0–15.1 includedWindows isn't available; the caller falls back to the picker's own
        // stream. For the single-window demo path the app targets 15.2+ resolution.
        return nil
    }
}
