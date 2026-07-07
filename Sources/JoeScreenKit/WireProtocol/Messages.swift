import Foundation

// All concrete data-channel payloads. Each conforms to `WireMessage`, which binds it to exactly
// one `MessageKind` (and therefore one channel with fixed reliability/ordering). Coordinates that
// cross machines are ALWAYS normalized [0,1] in the shared window's space so receiver-side local
// resizing never changes the mapping (spec §3.4/§3.5).

/// A point in a window's normalized coordinate space: (0,0) top-left, (1,1) bottom-right.
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

// MARK: - Cursor (unreliable / unordered, latest-wins)

public struct CursorMove: WireMessage {
    public static let kind: MessageKind = .cursorMove
    public var windowID: WindowID
    public var point: NormalizedPoint
    /// Sender clock (seconds). Latest-wins: a stale arrival (older timestamp) is discarded.
    public var timestamp: Double
    public init(windowID: WindowID, point: NormalizedPoint, timestamp: Double) {
        self.windowID = windowID; self.point = point; self.timestamp = timestamp
    }
}

// MARK: - Discrete input (reliable / ordered, seq-tracked)

public enum InputEventKind: String, Codable, Sendable {
    case keyDown, keyUp, mouseDown, mouseUp, click, scroll
}

public struct InputEvent: WireMessage {
    public static let kind: MessageKind = .inputEvent
    public var eventKind: InputEventKind
    public var windowID: WindowID
    /// Normalized cursor position at the time of the event (for mouse events).
    public var point: NormalizedPoint?
    /// Virtual keycode for key events (CGKeyCode-compatible on the owner Mac).
    public var keyCode: UInt16?
    /// Modifier bitmask (owner maps to CGEventFlags).
    public var modifiers: UInt32
    /// Scroll deltas (line/pixel) for `.scroll`.
    public var scrollDX: Double?
    public var scrollDY: Double?

    public init(
        eventKind: InputEventKind,
        windowID: WindowID,
        point: NormalizedPoint? = nil,
        keyCode: UInt16? = nil,
        modifiers: UInt32 = 0,
        scrollDX: Double? = nil,
        scrollDY: Double? = nil
    ) {
        self.eventKind = eventKind; self.windowID = windowID; self.point = point
        self.keyCode = keyCode; self.modifiers = modifiers
        self.scrollDX = scrollDX; self.scrollDY = scrollDY
    }
}

// MARK: - Capability grant/revoke (input channel, so grants serialize with the input they gate)

/// Rights an owner grants a participant over one window. `write` gates injection; `draw` gates ink.
public struct ControlRights: OptionSet, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let write = ControlRights(rawValue: 1 << 0)
    public static let draw  = ControlRights(rawValue: 1 << 1)
}

public struct CapabilityGrant: WireMessage {
    public static let kind: MessageKind = .capabilityGrant
    public var participantID: ParticipantID
    public var windowID: WindowID
    public var rights: ControlRights
    /// Sender-clock expiry (seconds). `nil` = no expiry (revoke-only).
    public var expiry: Double?
    public init(participantID: ParticipantID, windowID: WindowID, rights: ControlRights, expiry: Double? = nil) {
        self.participantID = participantID; self.windowID = windowID
        self.rights = rights; self.expiry = expiry
    }
}

public struct CapabilityRevoke: WireMessage {
    public static let kind: MessageKind = .capabilityRevoke
    public var participantID: ParticipantID
    public var windowID: WindowID
    public init(participantID: ParticipantID, windowID: WindowID) {
        self.participantID = participantID; self.windowID = windowID
    }
}

// MARK: - Clipboard (reliable / ordered)

public enum ClipboardType: String, Codable, Sendable {
    case utf8Text, rtf, image
}

public struct ClipboardPayload: WireMessage {
    public static let kind: MessageKind = .clipboard
    public var type: ClipboardType
    /// For `.utf8Text` this is UTF-8 bytes with EXACT whitespace/newlines preserved (F6).
    public var bytes: Data
    public var sourceWindowID: WindowID?
    public init(type: ClipboardType, bytes: Data, sourceWindowID: WindowID? = nil) {
        self.type = type; self.bytes = bytes; self.sourceWindowID = sourceWindowID
    }
}

// MARK: - Terminal (reliable / ordered) — F12

public struct TerminalData: WireMessage {
    public static let kind: MessageKind = .terminalData
    /// Raw PTY bytes, already run through `SecretRedactor` before transmit.
    public var ptyBytes: Data
    public init(ptyBytes: Data) { self.ptyBytes = ptyBytes }
}

public struct TerminalControl: WireMessage {
    public static let kind: MessageKind = .terminalControl
    public var cols: UInt16?
    public var rows: UInt16?
    public var writerID: ParticipantID?
    public init(cols: UInt16? = nil, rows: UInt16? = nil, writerID: ParticipantID? = nil) {
        self.cols = cols; self.rows = rows; self.writerID = writerID
    }
}

// MARK: - Draw (reliable / ordered-per-author) — F9

public struct RGBAColor: Codable, Sendable, Equatable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
}

public struct DrawOp: WireMessage {
    public static let kind: MessageKind = .drawOp
    public var authorID: ParticipantID
    /// Monotonic per-author sequence; orders strokes within one author's stream.
    public var authorSeq: UInt64
    public var windowID: WindowID
    public var points: [NormalizedPoint]
    public var color: RGBAColor
    public var width: Double
    public init(authorID: ParticipantID, authorSeq: UInt64, windowID: WindowID,
                points: [NormalizedPoint], color: RGBAColor, width: Double) {
        self.authorID = authorID; self.authorSeq = authorSeq; self.windowID = windowID
        self.points = points; self.color = color; self.width = width
    }
}

public struct DrawClear: WireMessage {
    public static let kind: MessageKind = .drawClear
    public var authorID: ParticipantID
    public var windowID: WindowID
    public init(authorID: ParticipantID, windowID: WindowID) {
        self.authorID = authorID; self.windowID = windowID
    }
}

public struct DrawUndo: WireMessage {
    public static let kind: MessageKind = .drawUndo
    public var authorID: ParticipantID
    public var windowID: WindowID
    public init(authorID: ParticipantID, windowID: WindowID) {
        self.authorID = authorID; self.windowID = windowID
    }
}

// MARK: - Coordination state (reliable / ordered) — M0

/// A full mirrored `RoomModel` snapshot broadcast by the sharer over the `state` channel. Receivers
/// apply it only if `model.revision` is newer than their current copy (last-writer-wins), so
/// reordered/stale snapshots are dropped. This is the durable, self-contained state message a late
/// joiner needs to catch up in one shot (spec §M0 / D9 / RoomModel sync model).
public struct RoomSnapshot: WireMessage {
    public static let kind: MessageKind = .roomSnapshot
    public var model: RoomModel
    public init(model: RoomModel) { self.model = model }
}

/// A discrete share/unshare notification on the `state` channel. Snapshots carry authoritative
/// state; share events let peers react to a single window appearing/disappearing without diffing a
/// whole snapshot (e.g. to open/close a native viewer window promptly). `revision` is the
/// `RoomModel.revision` the event corresponds to, so a peer can order it against snapshots.
public struct ShareEvent: WireMessage {
    public static let kind: MessageKind = .shareEvent
    public enum Action: String, Codable, Sendable, Equatable {
        case shared     // a window became shared
        case unshared   // a window stopped being shared
    }
    public var action: Action
    public var windowID: WindowID
    public var ownerID: ParticipantID
    /// The `RoomModel.revision` at which this event took effect (for ordering against snapshots).
    public var revision: UInt64
    public init(action: Action, windowID: WindowID, ownerID: ParticipantID, revision: UInt64) {
        self.action = action; self.windowID = windowID
        self.ownerID = ownerID; self.revision = revision
    }
}
