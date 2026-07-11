import Foundation

#if os(macOS)
import CoreGraphics

/// Watches one on-screen window for a SIZE change and reports the new point-size, so a shared
/// window that the sharer resizes stays aspect-true on every receiver (spec §3 / M9).
///
/// ScreenCaptureKit does not surface a "window resized" event (the SCStream keeps delivering frames
/// at the ORIGINAL configured dimensions — a resized window is letterboxed/cropped inside the old
/// buffer until the config is rebuilt), so this polls `CGWindowListCopyWindowInfo` at 4 Hz, the same
/// cheap pattern as `MinimizeUnshareWatcher`. The raw poll is intentionally noisy: the capture actor
/// runs it through `ResizeStabilizer` (JoeScreenKit, unit-tested) so a full `updateConfiguration`
/// fires only on a settled resize, never mid-drag.
///
/// Reports the window's bounds in POINTS (CGWindowList reports points); the capture side multiplies
/// by the backing scale for pixel dimensions.
final class WindowResizeWatcher: @unchecked Sendable {
    private let cgWindowID: CGWindowID
    private let onSize: @Sendable (CGSize) -> Void
    private let queue = DispatchQueue(label: "com.joescreen.capture.resize", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(cgWindowID: CGWindowID, onSize: @escaping @Sendable (CGSize) -> Void) {
        self.cgWindowID = cgWindowID
        self.onSize = onSize
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25) // 4 Hz
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let size = Self.windowSize(cgWindowID) else { return }
        onSize(size)
    }

    /// Current point-size of the window from its `kCGWindowBounds` entry; nil if the window isn't
    /// currently listed (minimized/closed — handled by `MinimizeUnshareWatcher`, not here).
    static func windowSize(_ windowID: CGWindowID) -> CGSize? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            guard let num = info[kCGWindowNumber as String] as? CGWindowID, num == windowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            return bounds.size
        }
        return nil
    }
}

#endif
