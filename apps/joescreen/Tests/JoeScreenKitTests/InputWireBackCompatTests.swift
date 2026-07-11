import XCTest
@testable import JoeScreenKit

/// F4 wire additions: tolerant InputEventKind decode, InputEvent.text back-compat, ControlRequest.
final class InputWireBackCompatTests: XCTestCase {

    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()

    // MARK: - Tolerant InputEventKind

    func testKnownKindsRoundTrip() {
        for k in [InputEventKind.keyDown, .keyUp, .mouseDown, .mouseUp, .click, .scroll, .mouseMove, .mouseDrag] {
            XCTAssertEqual(InputEventKind(rawValue: k.rawValue), k)
            XCTAssertTrue(k.isKnown)
        }
    }

    func testUnknownKindDecodesToUnsupportedNotThrow() throws {
        // The KEY back-compat property: a newer peer sends a kind this build doesn't know. An OLD
        // plain-String enum would throw and break the whole input channel; ours maps to .unsupported.
        let json = "\"someFutureGesture\"".data(using: .utf8)!
        let decoded = try decoder.decode(InputEventKind.self, from: json)
        XCTAssertEqual(decoded, .unsupported("someFutureGesture"))
        XCTAssertFalse(decoded.isKnown)
        // Round-trips (preserves the raw value).
        XCTAssertEqual(try encoder.encode(decoded), json)
    }

    func testInputEventWithUnknownKindDecodesAndIsIgnorable() throws {
        // A full InputEvent carrying a future kind decodes cleanly; injection logic checks .isKnown.
        let w = WindowID()
        let json = """
        {"eventKind":"warpGesture","modifiers":0,"windowID":"\(w.uuidString)"}
        """.data(using: .utf8)!
        let ev = try decoder.decode(InputEvent.self, from: json)
        XCTAssertFalse(ev.eventKind.isKnown)
        XCTAssertNil(ev.text)
    }

    // MARK: - InputEvent.text back-compat

    func testInputEventTextRoundTrips() throws {
        let ev = InputEvent(eventKind: .keyDown, windowID: WindowID(), text: "hello world")
        let back = try decoder.decode(InputEvent.self, from: try encoder.encode(ev))
        XCTAssertEqual(back.text, "hello world")
        XCTAssertEqual(back, ev)
    }

    func testInputEventDecodesOldPayloadWithoutText() throws {
        // An old peer's InputEvent has no `text` key → decodes to nil (synthesized decodeIfPresent).
        let w = WindowID()
        let json = """
        {"eventKind":"keyDown","keyCode":4,"modifiers":0,"windowID":"\(w.uuidString)"}
        """.data(using: .utf8)!
        let ev = try decoder.decode(InputEvent.self, from: json)
        XCTAssertEqual(ev.eventKind, .keyDown)
        XCTAssertNil(ev.text)
    }

    // MARK: - ControlRequest (kind 13)

    func testControlRequestRoundTripAndChannel() throws {
        let req = ControlRequest(participantID: ParticipantID(), windowID: WindowID(), action: .request)
        let env = try WireCodec.pack(req, sender: req.participantID, seq: 1)
        let bytes = try WireCodec.encode(env)
        let decodedEnv = try WireCodec.decode(bytes)
        XCTAssertEqual(decodedEnv.kind, .controlRequest)
        // Rides the input channel (serializes with the input it gates).
        XCTAssertEqual(MessageKind.controlRequest.channel, .input)
        let back = try WireCodec.unpack(decodedEnv, as: ControlRequest.self)
        XCTAssertEqual(back, req)
    }

    func testControlRequestKind13NotRenumbered() {
        XCTAssertEqual(MessageKind.controlRequest.rawValue, 13)
        // The reserved history is intact.
        XCTAssertEqual(MessageKind.roomSnapshot.rawValue, 11)
        XCTAssertEqual(MessageKind.shareEvent.rawValue, 12)
    }

    func testUnknownMessageKindStillDecodesToNil() throws {
        // Forward-compat: a future kind 14 an old build doesn't know decodes to kind==nil (skip).
        let owner = ParticipantID()
        let env = Envelope(kind: .controlRequest, senderID: owner, seq: 1, body: Data())
        var raw = try WireCodec.encode(env)
        // Tamper the tag to 99 (unknown) and confirm decode yields kind==nil, not a throw.
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var mutable = obj; mutable["k"] = 99
        raw = try JSONSerialization.data(withJSONObject: mutable)
        let decoded = try WireCodec.decode(raw)
        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.rawKind, 99)
    }
}
