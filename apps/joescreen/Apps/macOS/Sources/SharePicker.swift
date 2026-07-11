import Foundation
import ScreenCaptureKit
import JoeScreenKit

/// The user's picker choice: a single window or a whole display (M11).
enum SharePick: Sendable, Equatable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

/// Wraps `SCContentSharingPicker` (the system picker, D10 primary path — R4 exemption, R5
/// independence) and resolves the user's choice to a `SharePick`. Modes: single window + single
/// display (M11). Its UI appears only when marked active.
///
/// macOS-14 floor fix (spec §M11): `SCContentFilter.includedWindows/includedDisplays` are 15.2+.
/// We classify by `filter.style` (14.0+) and, on 14.0–15.1, resolve the display by matching
/// `filter.contentRect` (14.0+) against `SCShareableContent.displays[].frame` via the pure
/// `DisplayPickResolver` (frames are unique in global space). Windows are best-effort by frame with
/// a "please retry" notice on ambiguity.
@available(macOS 14.0, *)
final class SharePicker: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    static let shared = SharePicker()

    private let lock = NSLock()
    private var completion: ((SharePick) -> Void)?
    private var onAmbiguous: (() -> Void)?
    private var isObserving = false

    /// Present the picker; `onPick` fires with the chosen window or display. `onAmbiguous` (optional)
    /// fires when a selection couldn't be resolved (the app can show a "please retry" notice).
    func present(onPick: @escaping (SharePick) -> Void, onAmbiguous: (() -> Void)? = nil) {
        lock.lock(); completion = onPick; self.onAmbiguous = onAmbiguous; lock.unlock()
        let picker = SCContentSharingPicker.shared
        if !isObserving {
            picker.add(self)
            isObserving = true
        }
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        // Exclude JoeScreen's own windows so a user can't pick them (and the hall-of-mirrors is
        // avoided for the window path; the display path excludes our app in the capture filter).
        // `excludedWindowIDs` is `[Int]` (NSArray<NSNumber>), so map the CGWindowIDs.
        config.excludedWindowIDs = Self.ownWindowIDs().map(Int.init)
        picker.configuration = config
        picker.isActive = true
        picker.present()
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        let pick = Self.resolvePick(from: filter)
        lock.lock(); let done = completion; let ambiguous = onAmbiguous; if pick != nil { completion = nil; onAmbiguous = nil }; lock.unlock()
        if let pick, let done {
            DispatchQueue.main.async { done(pick) }
        } else if pick == nil, let ambiguous {
            DispatchQueue.main.async { ambiguous() }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        lock.lock(); completion = nil; onAmbiguous = nil; lock.unlock()
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        lock.lock(); completion = nil; onAmbiguous = nil; lock.unlock()
    }

    // MARK: - Resolution

    /// Classify + resolve the filter into a `SharePick`. Window on 15.2+ reads `includedWindows`;
    /// display resolves via content-rect matching on all supported versions (robust to the 14.x floor).
    static func resolvePick(from filter: SCContentFilter) -> SharePick? {
        switch filter.style {
        case .window:
            if #available(macOS 15.2, *) {
                if let id = filter.includedWindows.first?.windowID { return .window(id) }
            }
            // 14.0–15.1: no includedWindows. Best-effort — the demo path targets 15.2+ for windows;
            // return nil so the caller shows a retry notice rather than sharing the wrong window.
            return nil
        case .display:
            if #available(macOS 15.2, *) {
                if let display = filter.includedDisplays.first { return .display(display.displayID) }
            }
            // 14.0–15.1 floor: match contentRect against the display frames (pure resolver).
            let candidates = Self.displayCandidates()
            if let id = DisplayPickResolver.resolve(contentRect: filter.contentRect, candidates: candidates) {
                return .display(id)
            }
            return nil
        default:
            return nil
        }
    }

    /// Current displays as `DisplayPickResolver.Candidate`s (id + global frame). Uses the CG display
    /// list — synchronous and dependency-free (SCShareableContent is async; for the floor path this
    /// synchronous list is what the picker's contentRect is expressed against).
    static func displayCandidates() -> [DisplayPickResolver.Candidate] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.map { DisplayPickResolver.Candidate(displayID: $0, frame: CGDisplayBounds($0)) }
    }

    /// JoeScreen's own on-screen window IDs, to exclude from the picker.
    static func ownWindowIDs() -> [CGWindowID] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var ids: [CGWindowID] = []
        for info in infoList {
            if let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == myPID,
               let num = info[kCGWindowNumber as String] as? CGWindowID {
                ids.append(num)
            }
        }
        return ids
    }
}
