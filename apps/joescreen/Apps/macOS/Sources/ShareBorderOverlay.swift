import AppKit

/// A borderless, click-through overlay window that draws a 3pt border around the display currently
/// being screen-shared (M11 sharer affordance — no PiP in v1). Invisible to receivers because
/// JoeScreen's own windows are excluded from the capture filter (the hall-of-mirrors fix), so the
/// sharer sees the border but peers see the clean screen.
@MainActor
final class ShareBorderOverlay {
    private var window: NSWindow?

    /// Show the border around `displayID`. Idempotent — re-showing moves it to the given display.
    func show(displayID: CGDirectDisplayID) {
        hide()
        let appKitFrame = Self.appKitFrame(for: displayID)

        let w = NSWindow(contentRect: appKitFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .statusBar               // above normal windows, below the menu bar's own overlays
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true        // click-through: never intercepts the sharer's input
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = BorderView()
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    /// The AppKit (bottom-left origin) frame for a display, so the border window exactly covers it.
    ///
    /// Multi-display fix: prefer the matching `NSScreen`'s `.frame` — those are ALREADY in AppKit
    /// global coordinates, so no manual flip (and its multi-monitor pitfalls) is needed. This is what
    /// makes the border cover the WHOLE correct screen on a 2-monitor setup, where the previous manual
    /// flip (using `max(all screens' maxY)` as the reference) mislocated/undersized the border on the
    /// non-primary display.
    ///
    /// Fallback (no matching NSScreen — shouldn't happen for a shareable display): flip `CGDisplayBounds`
    /// against the PRIMARY display's height, since AppKit's global origin is the primary display's
    /// bottom-left — NOT against the union of all screens (the old bug).
    private static func appKitFrame(for displayID: CGDirectDisplayID) -> NSRect {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            // The value is an NSNumber wrapping the CGDirectDisplayID.
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }) {
            return screen.frame
        }
        let bounds = CGDisplayBounds(displayID)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.maxY
        return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                      width: bounds.width, height: bounds.height)
    }
}

/// Draws a 3pt inset stroke around its bounds (the "you are sharing this screen" frame).
private final class BorderView: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(rect: inset)
        path.lineWidth = 3
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}
