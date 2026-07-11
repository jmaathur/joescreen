import Foundation
import JoeScreenKit

#if os(macOS)
import CoreGraphics
import Carbon.HIToolbox

/// Synthesizes and posts the actual `CGEvent`s for `CGEventInjector` (macOS-only). Separated so the
/// injector's public API compiles on any host and the platform code is isolated. Posts per the
/// chosen `InjectionStrategy`.
enum CGEventSynth {

    /// Build + post the CGEvent(s) for `event` at CG-global `point`. Returns whether anything posted.
    static func post(event: InputEvent, at point: CGPoint?, strategy: InjectionStrategy, ownerPID: Int32?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags = CGEventFlags(rawValue: UInt64(event.modifiers))

        switch event.eventKind {
        case .mouseDown:
            return postMouse(source, .leftMouseDown, .left, point, flags, strategy, ownerPID)
        case .mouseUp:
            return postMouse(source, .leftMouseUp, .left, point, flags, strategy, ownerPID)
        case .mouseMove:
            return postMouse(source, .mouseMoved, .left, point, flags, strategy, ownerPID)
        case .mouseDrag:
            return postMouse(source, .leftMouseDragged, .left, point, flags, strategy, ownerPID)
        case .click:
            // A click expands to down+up (the planner normally does this; support it directly too).
            let d = postMouse(source, .leftMouseDown, .left, point, flags, strategy, ownerPID)
            let u = postMouse(source, .leftMouseUp, .left, point, flags, strategy, ownerPID)
            return d && u
        case .scroll:
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(event.scrollDY ?? 0), wheel2: Int32(event.scrollDX ?? 0), wheel3: 0) else { return false }
            e.flags = flags
            return dispatch(e, strategy, ownerPID)
        case .keyDown, .keyUp:
            // Prefer a text run (Unicode) when present; else a keycode.
            if let text = event.text, !text.isEmpty {
                return postText(source, text, strategy, ownerPID)
            }
            guard let code = event.keyCode,
                  let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: event.eventKind == .keyDown) else { return false }
            e.flags = flags
            return dispatch(e, strategy, ownerPID)
        case .unsupported:
            // A kind this build doesn't understand — ignore (never inject something unknown).
            return false
        }
    }

    private static func postMouse(_ source: CGEventSource?, _ type: CGEventType, _ button: CGMouseButton,
                                  _ point: CGPoint?, _ flags: CGEventFlags, _ strategy: InjectionStrategy, _ pid: Int32?) -> Bool {
        guard let point else { return false }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return false }
        e.flags = flags
        return dispatch(e, strategy, pid)
    }

    /// Type a Unicode run as a single keyboard event carrying the string (keyDown then keyUp).
    private static func postText(_ source: CGEventSource?, _ text: String, _ strategy: InjectionStrategy, _ pid: Int32?) -> Bool {
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        return dispatch(down, strategy, pid) && dispatch(up, strategy, pid)
    }

    /// Post `e` per the strategy. hidTap posts to the HID tap (moves the physical cursor); postToPid
    /// targets a specific process (unreliable to unfocused windows, R26); hybrid tries pid then hidTap.
    private static func dispatch(_ e: CGEvent, _ strategy: InjectionStrategy, _ pid: Int32?) -> Bool {
        switch strategy {
        case .hidTap:
            e.post(tap: .cghidEventTap)
            return true
        case .postToPid:
            guard let pid else { e.post(tap: .cghidEventTap); return true } // no pid → fall back
            e.postToPid(pid)
            return true
        case .hybrid:
            if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
            return true
        }
    }
}

#endif
