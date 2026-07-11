import XCTest
@testable import JoeScreenKit

final class ShareTrackNameTests: XCTestCase {

    // MARK: - Byte-identical window contract (must match the pre-seam LiveKitTransport format)

    func testWindowEncodeIsByteIdenticalToLegacyFormat() {
        let id = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
        // The legacy `LiveKitTransport.trackName(for:)` produced exactly this. Extending the
        // contract must NOT change the bytes for the window case (§2 track-name contract).
        XCTAssertEqual(ShareTrackName.encode(kind: .window, windowID: id),
                       "window:3F2504E0-4F89-41D3-9A0C-0305E82C3301")
    }

    func testWindowRoundTrip() {
        let id = WindowID()
        let name = ShareTrackName.encode(kind: .window, windowID: id)
        let parsed = ShareTrackName.decode(name)
        XCTAssertEqual(parsed, ShareTrackName.Parsed(kind: .window, windowID: id))
        XCTAssertEqual(ShareTrackName.windowID(from: name), id)
    }

    // MARK: - Display (M11 additive)

    func testDisplayEncodeUsesDisplayPrefix() {
        let id = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
        XCTAssertEqual(ShareTrackName.encode(kind: .display, windowID: id),
                       "display:3F2504E0-4F89-41D3-9A0C-0305E82C3301")
    }

    func testDisplayRoundTrip() {
        let id = WindowID()
        let name = ShareTrackName.encode(kind: .display, windowID: id)
        XCTAssertEqual(ShareTrackName.decode(name), ShareTrackName.Parsed(kind: .display, windowID: id))
        XCTAssertEqual(ShareTrackName.windowID(from: name), id)
    }

    // MARK: - Garbage / forward-compat degradation

    func testCameraNameParsesToNil() {
        // LiveKit names camera tracks "camera" — never a share name.
        XCTAssertNil(ShareTrackName.decode("camera"))
        XCTAssertNil(ShareTrackName.windowID(from: "camera"))
    }

    func testUnknownPrefixParsesToNil() {
        // A FUTURE prefix an old build doesn't know must decode to nil (ignore), not crash.
        let id = UUID().uuidString
        XCTAssertNil(ShareTrackName.decode("region:\(id)"))
    }

    func testGarbageInputsParseToNil() {
        XCTAssertNil(ShareTrackName.decode(""))
        XCTAssertNil(ShareTrackName.decode("window:"))
        XCTAssertNil(ShareTrackName.decode("window:not-a-uuid"))
        XCTAssertNil(ShareTrackName.decode("no-colon-at-all"))
        XCTAssertNil(ShareTrackName.decode(":"))
        // Right prefix, extra colon-suffixed junk after the UUID → not a clean UUID → nil.
        XCTAssertNil(ShareTrackName.decode("window:\(UUID().uuidString):extra"))
    }

    func testWindowIdConvenienceMatchesLegacyParser() {
        // Both kinds surface a windowID; garbage surfaces nil.
        let id = WindowID()
        XCTAssertEqual(ShareTrackName.windowID(from: "window:\(id.uuidString)"), id)
        XCTAssertEqual(ShareTrackName.windowID(from: "display:\(id.uuidString)"), id)
        XCTAssertNil(ShareTrackName.windowID(from: "camera"))
    }
}
