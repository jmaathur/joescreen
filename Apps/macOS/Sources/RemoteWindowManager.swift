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

    // MARK: - Open / close

    func open(_ remote: RemoteVideoWindow) {
        guard windows[remote.windowID] == nil, let model else { return }

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
        window.makeKeyAndOrderFront(nil)
        windows[remote.windowID] = window
    }

    func close(_ windowID: WindowID) {
        windows[windowID]?.close()
        windows[windowID] = nil
        overlayModels[windowID] = nil
        cursorState[windowID] = nil
    }

    func closeAll() {
        for w in windows.values { w.close() }
        windows.removeAll()
        overlayModels.removeAll()
        cursorState.removeAll()
    }

    // MARK: - Cursors (M6)

    /// Update a remote participant's cursor position within a window and push it to the overlay.
    func updateRemoteCursor(windowID: WindowID, participant: ParticipantID, point: NormalizedPoint) {
        cursorState[windowID, default: [:]][participant] = point
        overlayModels[windowID]?.cursors = cursorState[windowID] ?? [:]
    }
}
