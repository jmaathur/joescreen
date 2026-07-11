import XCTest
@testable import JoeScreenKit

final class TrackClassifierTests: XCTestCase {

    // MARK: - Window/display share names win regardless of source

    func testWindowNameRoutesToWindowShare() {
        let id = WindowID()
        let name = ShareTrackName.encode(kind: .window, windowID: id)
        XCTAssertEqual(TrackClassifier.classify(name: name, source: .screenShareVideo), .windowShare(id))
        // Name wins even if the SDK reported a surprising source.
        XCTAssertEqual(TrackClassifier.classify(name: name, source: .camera), .windowShare(id))
        XCTAssertEqual(TrackClassifier.classify(name: name, source: .other), .windowShare(id))
    }

    func testDisplayNameRoutesToWindowShare() {
        let id = WindowID()
        let name = ShareTrackName.encode(kind: .display, windowID: id)
        XCTAssertEqual(TrackClassifier.classify(name: name, source: .screenShareVideo), .windowShare(id))
    }

    // MARK: - Camera

    func testCameraSourceWithNonShareNameRoutesToCamera() {
        // LiveKit names camera tracks "camera" — not a share name.
        XCTAssertEqual(TrackClassifier.classify(name: "camera", source: .camera), .camera)
        XCTAssertEqual(TrackClassifier.classify(name: "", source: .camera), .camera)
        XCTAssertEqual(TrackClassifier.classify(name: "anything", source: .camera), .camera)
    }

    // MARK: - Precedence: a share NAME beats a camera SOURCE

    func testShareNameBeatsCameraSourcePrecedence() {
        // The verified precedence trap: a parseable share name wins even when source==.camera.
        let id = WindowID()
        let name = ShareTrackName.encode(kind: .window, windowID: id)
        XCTAssertEqual(TrackClassifier.classify(name: name, source: .camera), .windowShare(id))
    }

    // MARK: - Ignore (forward-compatible)

    func testUnknownSourceNonShareNameIgnored() {
        XCTAssertEqual(TrackClassifier.classify(name: "microphone", source: .other), .ignore)
        XCTAssertEqual(TrackClassifier.classify(name: "screen_share_audio", source: .other), .ignore)
        XCTAssertEqual(TrackClassifier.classify(name: "", source: .other), .ignore)
    }

    func testFuturePrefixIgnoredNotCrashed() {
        // A future track-name prefix an old build doesn't know, non-camera source → ignore (never crash).
        XCTAssertEqual(TrackClassifier.classify(name: "region:\(UUID().uuidString)", source: .other), .ignore)
        // Same future prefix but camera source → camera (the source is the fallback).
        XCTAssertEqual(TrackClassifier.classify(name: "region:\(UUID().uuidString)", source: .camera), .camera)
    }

    func testScreenShareVideoSourceWithGarbageNameIgnored() {
        // A screen-share-video source whose name doesn't parse (shouldn't happen, but be robust) is
        // ignored rather than mis-routed to a camera tile.
        XCTAssertEqual(TrackClassifier.classify(name: "not-a-share", source: .screenShareVideo), .ignore)
    }
}
