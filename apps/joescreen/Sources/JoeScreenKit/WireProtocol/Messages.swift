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

/// The kind of a discrete input event. TOLERANT decoding (F4): a plain `String` enum THROWS on an
/// unknown raw value, so an old peer would break the moment a newer peer sends `mouseMove`/`mouseDrag`
/// (added for remote control). The custom Codable maps any unrecognized raw value to `.unsupported`
/// so old peers decode + IGNORE it instead of failing the whole channel (the additive-only rule).
public enum InputEventKind: Sendable, Equatable {
    case keyDown, keyUp, mouseDown, mouseUp, click, scroll
    /// Remote-control additions (F4): a bare pointer move / a button-held drag.
    case mouseMove, mouseDrag
    /// An unknown raw value from a newer peer — decoded (never throws) and ignored by old logic.
    case unsupported(String)

    /// The wire string for this kind (round-trips through `unsupported`).
    public var rawValue: String {
        switch self {
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .mouseDown: return "mouseDown"
        case .mouseUp: return "mouseUp"
        case .click: return "click"
        case .scroll: return "scroll"
        case .mouseMove: return "mouseMove"
        case .mouseDrag: return "mouseDrag"
        case .unsupported(let raw): return raw
        }
    }

    /// Total: any string decodes (unknown → `.unsupported`), so old peers never throw on a new kind.
    public init(rawValue: String) {
        switch rawValue {
        case "keyDown": self = .keyDown
        case "keyUp": self = .keyUp
        case "mouseDown": self = .mouseDown
        case "mouseUp": self = .mouseUp
        case "click": self = .click
        case "scroll": self = .scroll
        case "mouseMove": self = .mouseMove
        case "mouseDrag": self = .mouseDrag
        default: self = .unsupported(rawValue)
        }
    }

    /// Whether this build understands the kind (an `.unsupported` value is ignored by injection logic).
    public var isKnown: Bool { if case .unsupported = self { return false }; return true }
}

extension InputEventKind: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
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
    /// Text to type (F4 text chunking): a run of characters injected as a unit. Optional +
    /// `decodeIfPresent` (synthesized for optionals) so old peers decode nil, never break.
    public var text: String?

    public init(
        eventKind: InputEventKind,
        windowID: WindowID,
        point: NormalizedPoint? = nil,
        keyCode: UInt16? = nil,
        modifiers: UInt32 = 0,
        scrollDX: Double? = nil,
        scrollDY: Double? = nil,
        text: String? = nil
    ) {
        self.eventKind = eventKind; self.windowID = windowID; self.point = point
        self.keyCode = keyCode; self.modifiers = modifiers
        self.scrollDX = scrollDX; self.scrollDY = scrollDY; self.text = text
    }
}

/// A participant's request to drive a window (F4, wire kind 13). The owner surfaces a consent prompt;
/// on approval it grants `.write` + sets Control mode. Appended kind — old peers decode nil/ignore.
public struct ControlRequest: WireMessage {
    public static let kind: MessageKind = .controlRequest
    public var participantID: ParticipantID
    public var windowID: WindowID
    public enum Action: String, Codable, Sendable, Equatable { case request, release }
    public var action: Action
    public init(participantID: ParticipantID, windowID: WindowID, action: Action) {
        self.participantID = participantID; self.windowID = windowID; self.action = action
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
    /// Replicated annotation ink (F9), so a LATE JOINER catches up on existing strokes in one shot.
    /// Optional + synthesized `decodeIfPresent` — an old peer (or a snapshot with no ink) decodes
    /// nil, never breaks (additive-only).
    public var draw: DrawModel?
    public init(model: RoomModel, draw: DrawModel? = nil) { self.model = model; self.draw = draw }
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
    /// Advisory metadata for the share (title/app/source pixels/kind). Optional + `decodeIfPresent`
    /// (Swift synthesizes it for optionals): an old peer that predates this field decodes it to
    /// `nil` — additive-only, never breaks (§2). Present on `.shared`; `nil` on `.unshared`.
    public var info: ShareInfo?
    public init(action: Action, windowID: WindowID, ownerID: ParticipantID, revision: UInt64,
                info: ShareInfo? = nil) {
        self.action = action; self.windowID = windowID
        self.ownerID = ownerID; self.revision = revision; self.info = info
    }
}
