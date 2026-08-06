import SwiftUI
import AppKit
import JoeScreenKit

/// Manages one real, movable/resizable `NSWindow` per remote shared window (spec §3 / M4). Each
/// window hosts a `RemoteVideoView` (live `SwiftUIVideoView` + owner-color border + cursor overlay).
/// This is what makes a peer's shared window "a real window on your desktop."
@MainActor
final class RemoteWindowManager {
    weak var model: AppModel?
    weak var cursorPump: CursorPump?

    private var windows: [WindowID: NSWindow] = [:]
    private var cursorState: [WindowID: [ParticipantID: NormalizedPoint]] = [:]
    /// Cursor-overlay views by window, so we can push updates without rebuilding the hosting view.
    private var overlayModels: [WindowID: CursorOverlayModel] = [:]
    /// Per-window close delegates (NSWindow.delegate is weak, so the manager must retain them).
    private var closeDelegates: [WindowID: WindowCloseDelegate] = [:]

    // MARK: - Open / close

    func open(_ remote: RemoteVideoWindow) {
        guard let model else { return }
        // Re-share / re-subscribe race: a window for this ID may still exist rendering the old dead
        // track (the model's `remoteWindows` entry was already overwritten). Close and replace it
        // so the new live track actually renders instead of the stale one.
        if windows[remote.windowID] != nil { close(remote.windowID) }

        let overlayModel = CursorOverlayModel()
        overlayModels[remote.windowID] = overlayModel

        let content = RemoteVideoView(window: remote)
            .environment(model)
            .environment(overlayModel)

        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Shared · \(model.shortLabel(for: remote.ownerID))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 800, height: 500))
        window.isReleasedWhenClosed = false
        window.center()
        // Cascade so multiple shared windows don't stack exactly.
        let cascade = CGFloat(windows.count) * 30
        var origin = window.frame.origin
        origin.x += cascade
        origin.y -= cascade
        window.setFrameOrigin(origin)
        // Drop the registry entry when the user closes the window via the traffic-light button;
        // otherwise the stale entry blocks a later re-share from reopening it.
        let closeDelegate = WindowCloseDelegate { [weak self] in
            self?.forget(remote.windowID)
        }
        window.delegate = closeDelegate
        closeDelegates[remote.windowID] = closeDelegate
        window.makeKeyAndOrderFront(nil)
        windows[remote.windowID] = window
    }

    func close(_ windowID: WindowID) {
        windows[windowID]?.close()
        forget(windowID)
    }

    func closeAll() {
        for w in windows.values { w.close() }
        windows.removeAll()
        overlayModels.removeAll()
        cursorState.removeAll()
        closeDelegates.removeAll()
    }

    /// Drop a closed window's registry entries without closing it (the window is already gone or
    /// closing — e.g. user close, where re-entering `close()` would be redundant).
    private func forget(_ windowID: WindowID) {
        windows[windowID] = nil
        overlayModels[windowID] = nil
        cursorState[windowID] = nil
        closeDelegates[windowID] = nil
    }

    // MARK: - Cursors (M6)

    /// Update a remote participant's cursor position within a window and push it to the overlay.
    func updateRemoteCursor(windowID: WindowID, participant: ParticipantID, point: NormalizedPoint) {
        cursorState[windowID, default: [:]][participant] = point
        overlayModels[windowID]?.cursors = cursorState[windowID] ?? [:]
    }
}

/// `NSWindowDelegate` that reports a user-initiated close (the traffic-light button) back to the
/// manager so it can drop the registry entry. One instance per window; the manager retains it
/// because `NSWindow.delegate` is weak.
@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
