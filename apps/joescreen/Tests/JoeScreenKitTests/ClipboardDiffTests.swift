import XCTest
@testable import JoeScreenKit

final class ClipboardDiffTests: XCTestCase {
    let window = UUID()

    func testChangeCountIncrementTriggersOneSend() throws {
        var e = ClipboardSyncEngine(initialChangeCount: 0)
        let out = try e.onPasteboardObserved(changeCount: 1, type: .utf8Text,
                                             bytes: Data("hi".utf8), sourceWindowID: window)
        XCTAssertNotNil(out)
        // Same changeCount → no traffic.
        let again = try e.onPasteboardObserved(changeCount: 1, type: .utf8Text,
                                               bytes: Data("hi".utf8), sourceWindowID: window)
        XCTAssertNil(again)
    }

    func testEchoSuppressionAfterApply() throws {
        var e = ClipboardSyncEngine(initialChangeCount: 0)
        let payload = ClipboardPayload(type: .utf8Text, bytes: Data("remote".utf8))
        _ = try e.prepareApply(payload) // we're about to write this remotely-sourced value locally
        // The pasteboard write bumps changeCount; observing it must NOT echo back out.
        let out = try e.onPasteboardObserved(changeCount: 1, type: .utf8Text,
                                             bytes: Data("remote".utf8), sourceWindowID: nil)
        XCTAssertNil(out, "our own applied write must not echo")
        // A genuinely new local change afterward DOES send.
        let out2 = try e.onPasteboardObserved(changeCount: 2, type: .utf8Text,
                                              bytes: Data("local edit".utf8), sourceWindowID: nil)
        XCTAssertNotNil(out2)
    }

    func testMultilineCodeByteIntact() throws {
        var e = ClipboardSyncEngine(initialChangeCount: 0)
        let code = "for i in 0..<3 {\n    print(i)\t// trailing tab \n}\n"
        let out = try e.onPasteboardObserved(changeCount: 1, type: .utf8Text,
                                             bytes: Data(code.utf8), sourceWindowID: nil)
        XCTAssertEqual(String(data: out!.bytes, encoding: .utf8), code)
    }

    func testOversizeRejected() {
        var e = ClipboardSyncEngine(limits: .init(maxTextBytes: 4), initialChangeCount: 0)
        XCTAssertThrowsError(try e.onPasteboardObserved(changeCount: 1, type: .utf8Text,
                                                        bytes: Data("toolong".utf8), sourceWindowID: nil)) { err in
            guard case ClipboardSyncEngine.RejectReason.tooLarge(.utf8Text, _, 4) = err else {
                return XCTFail("expected tooLarge, got \(err)")
            }
        }
    }

    func testImageDisallowed() {
        var e = ClipboardSyncEngine(limits: .init(allowImage: false), initialChangeCount: 0)
        XCTAssertThrowsError(try e.onPasteboardObserved(changeCount: 1, type: .image,
                                                        bytes: Data([0, 1, 2]), sourceWindowID: nil)) { err in
            guard case ClipboardSyncEngine.RejectReason.typeNotAllowed(.image) = err else {
                return XCTFail("expected typeNotAllowed, got \(err)")
            }
        }
    }
}
