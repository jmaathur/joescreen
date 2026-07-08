import Foundation

#if os(macOS)
import CoreGraphics

/// Watches one on-screen window for MINIMIZE and fires a callback so the share can end (spec §3.3 /
/// D10 / R13: minimize ⇒ unshare, distinct from off-Space which is a pause).
///
/// ScreenCaptureKit does not surface a "window minimized" event, so this polls the window list. A
/// minimized window disappears from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` (it's no longer
/// on-screen) while still existing in the full list — that transition is the minimize signal. Polling
/// at a low rate (4 Hz) is cheap and avoids a private-API dependency.
///
/// The fire-once contract: the callback runs at most once per watcher (a minimize is terminal for the
/// share); the caller stops the watcher after.
final class MinimizeUnshareWatcher: @unchecked Sendable {
    private let cgWindowID: CGWindowID
    private let onMinimized: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.joescreen.capture.minimize", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var fired = false
    private var seenOnScreen = false

    init(cgWindowID: CGWindowID, onMinimized: @escaping @Sendable () -> Void) {
        self.cgWindowID = cgWindowID
        self.onMinimized = onMinimized
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard !fired else { return }
        let onScreen = isWindowOnScreen(cgWindowID)
        // Establish a baseline: only treat a disappearance as a minimize AFTER we've seen it on-screen
        // at least once (so we don't fire before capture has really started).
        if onScreen {
            seenOnScreen = true
            return
        }
        if seenOnScreen {
            // Was on-screen, now isn't → minimized (or closed). Fire once.
            fired = true
            onMinimized()
            stop()
        }
    }

    /// Whether `windowID` currently appears in the on-screen window list.
    private func isWindowOnScreen(_ windowID: CGWindowID) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in infoList {
            if let num = info[kCGWindowNumber as String] as? CGWindowID, num == windowID {
                return true
            }
        }
        return false
    }
}

#endif
