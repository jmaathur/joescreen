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
        let frame = CGDisplayBounds(displayID)
        // CGDisplayBounds is top-left origin (global); convert to AppKit bottom-left for NSWindow.
        let appKitFrame = Self.toAppKit(globalTopLeft: frame)

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

    /// Convert a CG global (top-left origin) display rect to an AppKit (bottom-left origin) frame,
    /// using the total desktop height (max of all screen frames) as the flip reference.
    private static func toAppKit(globalTopLeft rect: CGRect) -> NSRect {
        let desktopMaxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? rect.maxY
        return NSRect(x: rect.minX, y: desktopMaxY - rect.maxY, width: rect.width, height: rect.height)
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
