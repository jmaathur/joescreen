import SwiftUI
import AppKit
import JoeScreenKit
import JoeScreenLiveKit

/// Manages one real, movable/resizable `NSWindow` per remote shared window (spec §3 / M4 / M9). Each
/// window hosts a `RemoteVideoView` (live `SwiftUIVideoView` + owner-color border + cursor overlay +
/// pause/reconnecting badges). This is what makes a peer's shared window "a real window on your
/// desktop." M9 makes it production-grade: aspect-true sizing (`VideoFitMath`), deterministic
/// placement (`WindowCascade`), a per-window `NSWindowDelegate` that routes close/miniaturize into
/// the lifecycle reducer, remembered frames for reopen, in-place track swap (no duplicate windows),
/// and focus/always-on-top policy.
@MainActor
final class RemoteWindowManager {
    weak var model: AppModel?
    weak var cursorPump: CursorPump?

    /// One managed window + its delegate + remembered frame.
    private final class Managed {
        let window: NSWindow
        let delegate: RemoteWindowDelegate
        var overlayModel: CursorOverlayModel
        /// The frame to restore on reopen (remembered at close).
        var rememberedFrame: NSRect?
        init(window: NSWindow, delegate: RemoteWindowDelegate, overlayModel: CursorOverlayModel) {
            self.window = window
            self.delegate = delegate
            self.overlayModel = overlayModel
        }
    }

    private var windows: [WindowID: Managed] = [:]
    private var cursorState: [WindowID: [ParticipantID: NormalizedPoint]] = [:]
    /// Frames remembered across a user-close so reopen restores position/size.
    private var rememberedFrames: [WindowID: NSRect] = [:]

    /// Whether newly-opened windows should steal focus ("Follow new shares"). Session pref, read live.
    var followNewShares: Bool = false

    // MARK: - Open / close

    func open(_ remote: RemoteVideoWindow) {
        guard windows[remote.windowID] == nil, let model else { return }

        let overlayModel = CursorOverlayModel()
        overlayModel.cursors = cursorState[remote.windowID] ?? [:]

        let content = RemoteVideoView(window: remote)
            .environment(model)
            .environment(overlayModel)

        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = titleFor(remote, model: model)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        // Aspect-true initial size: source aspect fitted to ~55% of the visible frame, or the 800×500
        // fallback until dimensions are known. Lock the content aspect so live resize stays true.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.initialContentSize(aspect: remote.aspectRatio, visible: visible)
        window.setContentSize(size)
        if let aspect = remote.aspectRatio, aspect > 0 {
            window.contentAspectRatio = NSSize(width: aspect, height: 1)
        }

        // Deterministic placement: prefer a remembered frame (reopen), else per-owner cascade.
        if let remembered = rememberedFrames[remote.windowID] {
            window.setFrame(remembered, display: false)
        } else {
            let (ownerIndex, windowIndex) = model.cascadeIndices(for: remote.windowID, owner: remote.ownerID)
            let frame = WindowCascade.frame(size: window.frame.size, ownerIndex: ownerIndex,
                                            windowIndex: windowIndex, visibleFrame: visible)
            window.setFrame(frame, display: false)
        }

        let delegate = RemoteWindowDelegate(windowID: remote.windowID) { [weak self] event in
            self?.handleDelegateEvent(remote.windowID, event)
        }
        window.delegate = delegate

        let managed = Managed(window: window, delegate: delegate, overlayModel: overlayModel)
        windows[remote.windowID] = managed

        // Focus policy: never steal focus by default (orderFrontRegardless). Only makeKeyAndOrderFront
        // if the user opted into "Follow new shares".
        if followNewShares {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Swap a new track / repaired chrome into an existing window WITHOUT reopening (reopen after a
    /// user-close, codec renegotiation, or owner repair). Rebuilds the hosting content so the new
    /// `RemoteVideoWindow` observable drives it; keeps the same NSWindow + frame.
    func replaceContent(_ remote: RemoteVideoWindow) {
        guard let managed = windows[remote.windowID], let model else { return }
        managed.overlayModel.cursors = cursorState[remote.windowID] ?? [:]
        let content = RemoteVideoView(window: remote)
            .environment(model)
            .environment(managed.overlayModel)
        managed.window.contentViewController = NSHostingController(rootView: content)
        managed.window.title = titleFor(remote, model: model)
        if let aspect = remote.aspectRatio, aspect > 0 {
            managed.window.contentAspectRatio = NSSize(width: aspect, height: 1)
        }
    }

    /// Refresh a window's title (owner repair / ShareInfo update) without rebuilding content.
    func refreshTitle(_ remote: RemoteVideoWindow) {
        guard let managed = windows[remote.windowID], let model else { return }
        managed.window.title = titleFor(remote, model: model)
    }

    func close(_ windowID: WindowID) {
        guard let managed = windows[windowID] else { return }
        // Remember the frame so a later reopen restores it.
        rememberedFrames[windowID] = managed.window.frame
        managed.window.delegate = nil // avoid a re-entrant willClose → lifecycle event on programmatic close
        managed.window.close()
        windows[windowID] = nil
        cursorState[windowID] = nil
    }

    func closeAll() {
        for managed in windows.values {
            managed.window.delegate = nil
            managed.window.close()
        }
        windows.removeAll()
        cursorState.removeAll()
        rememberedFrames.removeAll()
    }

    // MARK: - Focus / always-on-top

    /// Raise a window to the front (tile/menu "Focus").
    func focus(_ windowID: WindowID) {
        windows[windowID]?.window.makeKeyAndOrderFront(nil)
    }

    /// Raise all currently-open remote windows.
    func bringAllToFront() {
        for managed in windows.values { managed.window.orderFrontRegardless() }
    }

    /// Toggle always-on-top for one window (session-only). `.floating` keeps it above normal windows.
    func setAlwaysOnTop(_ windowID: WindowID, _ onTop: Bool) {
        windows[windowID]?.window.level = onTop ? .floating : .normal
    }

    var openWindowIDs: [WindowID] { Array(windows.keys) }

    // MARK: - Soft visibility (renderer detach is driven by the RemoteVideoWindow observable)

    /// Whether a window is currently fully occluded (for the occlusion soft-hide tier). AppKit's
    /// `occlusionState` flips when another window fully covers it.
    func isOccluded(_ windowID: WindowID) -> Bool {
        guard let w = windows[windowID]?.window else { return false }
        return !w.occlusionState.contains(.visible)
    }

    // MARK: - Cursors (M6)

    func updateRemoteCursor(windowID: WindowID, participant: ParticipantID, point: NormalizedPoint) {
        cursorState[windowID, default: [:]][participant] = point
        windows[windowID]?.overlayModel.cursors = cursorState[windowID] ?? [:]
    }

    // MARK: - Helpers

    private func handleDelegateEvent(_ windowID: WindowID, _ event: RemoteWindowDelegate.Event) {
        model?.remoteWindowDelegateEvent(windowID, event)
    }

    private func titleFor(_ remote: RemoteVideoWindow, model: AppModel) -> String {
        let owner = model.shortLabel(for: remote.ownerID)
        if let title = remote.title, !title.isEmpty {
            if let app = remote.appName, !app.isEmpty { return "\(title) — \(app) · \(owner)" }
            return "\(title) · \(owner)"
        }
        return "Shared · \(owner)"
    }

    /// Initial content size: source aspect fitted to ~55% of the visible frame; 800×500 fallback.
    static func initialContentSize(aspect: Double?, visible: CGRect) -> NSSize {
        guard let aspect, aspect > 0 else { return NSSize(width: 800, height: 500) }
        let budget = CGSize(width: visible.width * 0.55, height: visible.height * 0.55)
        let fitted = VideoFitMath.fittedSize(videoAspect: aspect, maxSize: budget)
        return NSSize(width: max(fitted.width, 320), height: max(fitted.height, 200))
    }
}

/// Per-window `NSWindowDelegate` that routes AppKit window events into the lifecycle reducer via a
/// closure. A user close ⇒ `.userClosed` (kept as a reopenable entry, downlink cut); miniaturize/
/// deminiaturize ⇒ `.miniaturized(Bool)` (soft renderer detach); occlusion ⇒ `.occluded(Bool)`.
@MainActor
final class RemoteWindowDelegate: NSObject, NSWindowDelegate {
    enum Event: Sendable, Equatable {
        case userClosed
        case miniaturized(Bool)
        case occluded(Bool)
    }

    let windowID: WindowID
    private let onEvent: (Event) -> Void

    init(windowID: WindowID, onEvent: @escaping (Event) -> Void) {
        self.windowID = windowID
        self.onEvent = onEvent
    }

    func windowWillClose(_ notification: Notification) {
        onEvent(.userClosed)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onEvent(.miniaturized(true))
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onEvent(.miniaturized(false))
        // Defense-in-depth (review hardening): AppKit does not guarantee a matching
        // occlusion-state notification pairs with every miniaturize/deminiaturize, so reconcile the
        // occluded flag from the window's ACTUAL occlusion state here. Without this, a miniaturize
        // that also flipped occluded=true could leave the reducer stuck at .hidden (black) after
        // restore if the occluded(false) notification never arrived.
        if let window = notification.object as? NSWindow {
            onEvent(.occluded(!window.occlusionState.contains(.visible)))
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onEvent(.occluded(!window.occlusionState.contains(.visible)))
    }
}
