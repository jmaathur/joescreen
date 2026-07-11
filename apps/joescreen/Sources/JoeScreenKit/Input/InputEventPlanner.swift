import Foundation

/// Turns high-level control INTENTS (a click, a drag, a text run) into the ordered sequence of
/// discrete `InputEvent`s the wire carries and the owner injects (F4). Pure logic so the expansion
/// (click → down+up, a drag → down + moves + up, a paragraph → chunked key runs) is unit-tested
/// without any CGEvent or network. The controller side plans; the `InputPump` sends the sequence in
/// order on the reliable/ordered `.input` channel; the owner's `CGEventInjector` executes each.
public enum InputEventPlanner {

    /// A high-level control intent from the driving participant.
    public enum Intent: Sendable, Equatable {
        /// A single click at a normalized point (down then up).
        case click(NormalizedPoint, modifiers: UInt32)
        /// A press-drag-release from `start` through `waypoints` to the last point.
        case drag(start: NormalizedPoint, waypoints: [NormalizedPoint], modifiers: UInt32)
        /// A bare pointer move (hover), no buttons.
        case move(NormalizedPoint)
        /// A scroll at a point.
        case scroll(NormalizedPoint, dx: Double, dy: Double)
        /// A single key press (down then up).
        case key(code: UInt16, modifiers: UInt32)
        /// Type a run of text (chunked so no single event carries an unbounded string).
        case type(String)
    }

    /// Max characters per `.text` InputEvent — keeps a single reliable message small (the Chunker
    /// handles anything larger at the transport, but chunking intent-side keeps each event bounded).
    public static let textChunkSize = 200

    /// Expand an intent into the ordered `InputEvent`s to send for `windowID`.
    public static func plan(_ intent: Intent, windowID: WindowID) -> [InputEvent] {
        switch intent {
        case let .click(point, modifiers):
            return [
                InputEvent(eventKind: .mouseDown, windowID: windowID, point: point, modifiers: modifiers),
                InputEvent(eventKind: .mouseUp, windowID: windowID, point: point, modifiers: modifiers),
            ]
        case let .drag(start, waypoints, modifiers):
            var events = [InputEvent(eventKind: .mouseDown, windowID: windowID, point: start, modifiers: modifiers)]
            // Intermediate waypoints are drags (button held); the LAST point is the release.
            let points = waypoints
            for (i, p) in points.enumerated() {
                let isLast = i == points.count - 1
                events.append(InputEvent(
                    eventKind: isLast ? .mouseUp : .mouseDrag, windowID: windowID, point: p, modifiers: modifiers))
            }
            // A drag with no waypoints releases at the start point.
            if points.isEmpty {
                events.append(InputEvent(eventKind: .mouseUp, windowID: windowID, point: start, modifiers: modifiers))
            }
            return events
        case let .move(point):
            return [InputEvent(eventKind: .mouseMove, windowID: windowID, point: point)]
        case let .scroll(point, dx, dy):
            return [InputEvent(eventKind: .scroll, windowID: windowID, point: point, scrollDX: dx, scrollDY: dy)]
        case let .key(code, modifiers):
            return [
                InputEvent(eventKind: .keyDown, windowID: windowID, keyCode: code, modifiers: modifiers),
                InputEvent(eventKind: .keyUp, windowID: windowID, keyCode: code, modifiers: modifiers),
            ]
        case let .type(text):
            return chunk(text).map { InputEvent(eventKind: .keyDown, windowID: windowID, text: $0) }
        }
    }

    /// Split `text` into ≤`textChunkSize`-character chunks WITHOUT splitting a grapheme cluster (so an
    /// emoji / combining sequence never straddles two events).
    public static func chunk(_ text: String, size: Int = textChunkSize) -> [String] {
        guard !text.isEmpty else { return [] }
        let n = max(1, size)
        var chunks: [String] = []
        var current = ""
        var count = 0
        for ch in text {
            current.append(ch)
            count += 1
            if count >= n { chunks.append(current); current = ""; count = 0 }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
