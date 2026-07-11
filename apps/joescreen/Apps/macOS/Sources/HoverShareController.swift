import AppKit
import JoeScreenKit

/// The CoScreen-signature hover "Share" tab (backlog #10). A global mouse monitor hit-tests the
/// window under the cursor (`WindowHitTester`) and shows a small non-activating floating "Share"
/// affordance; clicking it shares that window.
///
/// R4 SPIKE GATE: whether a NON-picker capture (going straight to `SCContentFilter` for the hovered
/// window without the system picker) re-prompts for Screen Recording on macOS 15 is unknown until the
/// Phase-0 R4 prompt-cadence spike runs (Human TODO). Until then this ships with `strategy = .picker`
/// — the hover tab PRE-SEEDS the system picker rather than bypassing it, which is always R4-safe. The
/// spike result flips `strategy` to `.direct` (a config change, not a rewrite).
@MainActor
final class HoverShareController {
    enum Strategy { case picker; case direct }

    weak var model: AppModel?
    /// R4-safe default until the spike (Human TODO): the tab opens the picker.
    var strategy: Strategy = .picker
    /// Session-scoped enable (default OFF — the global monitor only runs when the user opts in).
    private(set) var enabled = false

    private var monitor: Any?
    private let panel = HoverSharePanel()
    private var hoveredWindowID: UInt32?

    init(model: AppModel?) { self.model = model }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { startMonitor() } else { stopMonitor(); panel.orderOut(nil); hoveredWindowID = nil }
    }

    private func startMonitor() {
        // A global monitor sees mouse moves in OTHER apps (no local events needed for hit-testing).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateHover()
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation // AppKit bottom-left global
        let cg = Self.toCG(mouse)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let target = WindowHitTester.hit(point: cg, candidates: Self.candidates(), ownPID: ownPID) else {
            panel.orderOut(nil); hoveredWindowID = nil; return
        }
        hoveredWindowID = target
        panel.show(near: mouse) { [weak self] in self?.shareHovered() }
    }

    private func shareHovered() {
        guard let id = hoveredWindowID, let model else { return }
        switch strategy {
        case .picker:
            // R4-safe: go through the system picker (which the user then confirms). Pre-seeding the
            // picker to the hovered window would use SCContentSharingPicker.present(for:) once the
            // spike confirms it; for now open the normal picker.
            model.beginShare()
        case .direct:
            // Post-spike: capture the hovered window directly (the --share-window-id path).
            model.shareWindow(cgWindowID: id)
        }
        panel.orderOut(nil)
    }

    // MARK: - CG window snapshot

    static func candidates() -> [WindowHitTester.Candidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bDict as CFDictionary) else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            return WindowHitTester.Candidate(cgWindowID: id, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    /// Convert an AppKit bottom-left global point to CG top-left (for hit-testing against CG bounds).
    static func toCG(_ p: NSPoint) -> CGPoint {
        let maxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? p.y
        return CGPoint(x: p.x, y: maxY - p.y)
    }
}

/// A borderless, NON-ACTIVATING floating "Share" chip that follows the cursor near a hovered window.
@MainActor
private final class HoverSharePanel: NSObject {
    private let panel: NSPanel
    private var onClick: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 88, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init()
    }

    func show(near mouse: NSPoint, onClick: @escaping () -> Void) {
        self.onClick = onClick
        let button = NSButton(title: "Share", target: self, action: #selector(clicked))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 0, y: 0, width: 88, height: 30)
        panel.contentView = button
        panel.setFrameOrigin(NSPoint(x: mouse.x + 12, y: mouse.y + 12))
        panel.orderFrontRegardless()
    }

    func orderOut(_ sender: Any?) { panel.orderOut(sender) }

    @objc private func clicked() { onClick?() }
}
