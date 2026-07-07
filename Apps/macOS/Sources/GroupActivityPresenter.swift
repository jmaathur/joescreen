import Foundation
import JoeScreenKit

#if canImport(GroupActivities) && os(macOS)
import GroupActivities
import AppKit

/// Presents SharePlay start on macOS with the eligibility-gated fallback (spec R9 / M7).
///
/// Primary: `GroupActivitySharingController` (verified macOS 13+ in `_GroupActivities_AppKit`, but
/// spec-flagged as flaky — R9). Fallback: `prepareForActivation()` → `activate()` gated on
/// `isEligibleForGroupSession`. The `GroupSessionCoordinator` then picks up the resulting session via
/// `sessions()`.
///
/// Requires the group-session entitlement (TEAM_ID-gated). Runtime is a hardware step (PENDING).
@available(macOS 14.0, *)
@MainActor
public enum GroupActivityPresenter {

    public enum PresentError: Error {
        case noWindow
        case notEligible
    }

    /// Present the sharing controller for `activity` over the app's key window. Falls back to
    /// `prepareForActivation()`/`activate()` when eligible if the controller can't be presented.
    public static func present(_ activity: JoeScreenActivity) async throws {
        // Fallback path is gated on eligibility (R9): only attempt activate() when the system says a
        // group session is possible (e.g. an active FaceTime call). Eligibility lives on
        // GroupStateObserver, not the activity.
        let isEligible = GroupStateObserver().isEligibleForGroupSession
        if isEligible {
            do {
                try presentSharingController(activity)
                return
            } catch {
                // Controller failed (R9 flakiness) — fall through to prepare/activate.
            }
            let result = await activity.prepareForActivation()
            if result == .activationPreferred {
                _ = try await activity.activate()
                return
            }
            throw PresentError.notEligible
        } else {
            // Not in a group context yet — presenting the controller lets the user start one
            // (or start a FaceTime call). If there's no window to anchor it, surface an error.
            try presentSharingController(activity)
        }
    }

    /// Present `GroupActivitySharingController` anchored on the key window's content view controller.
    private static func presentSharingController(_ activity: JoeScreenActivity) throws {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
              let host = window.contentViewController else {
            throw PresentError.noWindow
        }
        let controller = try GroupActivitySharingController(activity)
        host.presentAsSheet(controller)
    }
}

#endif
