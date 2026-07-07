import XCTest
@testable import JoeScreenKit

final class WireProtocolRoundTripTests: XCTestCase {

    private let sender = UUID()
    private let window = UUID()

    // Every payload type encodes → decodes byte-stable through pack/unpack on its own channel.
    func testCursorRoundTrip() throws {
        let msg = CursorMove(windowID: window, point: NormalizedPoint(x: 0.25, y: 0.75), timestamp: 12.5)
        let env = try WireCodec.pack(msg, sender: sender)
        XCTAssertEqual(env.kind, .cursorMove)
        XCTAssertEqual(env.kind?.channel, .cursor)
        XCTAssertNil(env.seq, "cursor is unordered → no seq")
        let back = try WireCodec.unpack(env, as: CursorMove.self)
        XCTAssertEqual(back, msg)
    }

    func testInputRequiresSeqAndRoundTrips() throws {
        let msg = InputEvent(eventKind: .keyDown, windowID: window, keyCode: 4, modifiers: 0)
        // Packing an input event WITHOUT a seq must fail validation (input channel requires it).
        XCTAssertThrowsError(try WireCodec.pack(msg, sender: sender, seq: nil)) { err in
            XCTAssertEqual(err as? Envelope.ValidationError, .missingSequence(.inputEvent))
        }
        let env = try WireCodec.pack(msg, sender: sender, seq: 7)
        XCTAssertEqual(env.seq, 7)
        XCTAssertEqual(env.kind?.channel, .input)
        let back = try WireCodec.unpack(env, as: InputEvent.self)
        XCTAssertEqual(back, msg)
    }

    func testCursorRejectsSpuriousSeq() {
        let msg = CursorMove(windowID: window, point: .init(x: 0, y: 0), timestamp: 0)
        // A seq on an unordered channel is a contract violation.
        XCTAssertThrowsError(try WireCodec.pack(msg, sender: sender, seq: 1)) { err in
            XCTAssertEqual(err as? Envelope.ValidationError, .unexpectedSequence(.cursorMove))
        }
    }

    func testEnvelopeJSONIsByteStable() throws {
        let msg = ClipboardPayload(type: .utf8Text, bytes: Data("hello\n\tworld".utf8))
        let env = try WireCodec.pack(msg, sender: sender)
        let enc = WireCodec.makeEncoder()
        let a = try enc.encode(env)
        let b = try enc.encode(env)
        XCTAssertEqual(a, b, "sorted-keys encoder must be deterministic")
        let decoded = try JSONDecoder().decode(Envelope.self, from: a)
        XCTAssertEqual(decoded, env)
    }

    func testUnknownKindDecodesToSkippableEnvelopeNotFatal() throws {
        // Craft an envelope JSON with a kind tag this build doesn't know (e.g. 9999).
        let json = """
        {"v":1,"k":9999,"s":"\(sender.uuidString)","b":"AA=="}
        """
        let env = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        XCTAssertFalse(env.isKnownKind)
        XCTAssertEqual(env.rawKind, 9999)
        // validate() surfaces it as unknownKind (caller SKIPS, does not crash).
        XCTAssertThrowsError(try env.validate()) { err in
            XCTAssertEqual(err as? Envelope.ValidationError, .unknownKind(9999))
        }
    }

    func testKindMismatchOnUnpack() throws {
        let cursor = CursorMove(windowID: window, point: .init(x: 0, y: 0), timestamp: 0)
        let env = try WireCodec.pack(cursor, sender: sender)
        XCTAssertThrowsError(try WireCodec.unpack(env, as: InputEvent.self)) { err in
            XCTAssertEqual(err as? WireCodec.UnpackError, .kindMismatch(expected: .inputEvent, got: .cursorMove))
        }
    }

    func testClipboardPreservesExactWhitespaceAndNewlines() throws {
        // The F6 done-when: a multi-line code snippet survives byte-intact.
        let code = "func f() {\n\tlet x = 1  \n\treturn x\n}\n"
        let msg = ClipboardPayload(type: .utf8Text, bytes: Data(code.utf8))
        let env = try WireCodec.pack(msg, sender: sender)
        let back = try WireCodec.unpack(env, as: ClipboardPayload.self)
        XCTAssertEqual(String(data: back.bytes, encoding: .utf8), code)
    }

    // Channel matrix: every kind maps to the channel with the correct reliability/ordering.
    func testChannelMatrixIsCorrect() {
        XCTAssertEqual(MessageKind.cursorMove.policy.reliability, .unreliable)
        XCTAssertEqual(MessageKind.cursorMove.policy.ordering, .unordered)
        XCTAssertEqual(MessageKind.inputEvent.policy.reliability, .reliable)
        XCTAssertEqual(MessageKind.inputEvent.policy.ordering, .ordered)
        XCTAssertTrue(MessageKind.inputEvent.policy.requiresSequence)
        XCTAssertFalse(MessageKind.cursorMove.policy.requiresSequence)
        XCTAssertEqual(MessageKind.clipboard.policy.reliability, .reliable)
        XCTAssertEqual(MessageKind.terminalData.policy.channel, .terminal)
        XCTAssertEqual(MessageKind.drawOp.policy.ordering, .orderedPerAuthor)
        // Capability grants share the input channel so they serialize with the input they gate.
        XCTAssertEqual(MessageKind.capabilityGrant.channel, .input)
    }
}
