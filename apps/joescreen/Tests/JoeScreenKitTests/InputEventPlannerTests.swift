import XCTest
@testable import JoeScreenKit

final class InputEventPlannerTests: XCTestCase {

    private let w = WindowID()
    private let p = NormalizedPoint(x: 0.5, y: 0.5)

    func testClickIsDownThenUp() {
        let events = InputEventPlanner.plan(.click(p, modifiers: 0), windowID: w)
        XCTAssertEqual(events.map { $0.eventKind }, [.mouseDown, .mouseUp])
        XCTAssertTrue(events.allSatisfy { $0.point == p && $0.windowID == w })
    }

    func testClickCarriesModifiers() {
        let events = InputEventPlanner.plan(.click(p, modifiers: 0x100), windowID: w)
        XCTAssertTrue(events.allSatisfy { $0.modifiers == 0x100 })
    }

    func testDragIsDownDragsThenUp() {
        let a = NormalizedPoint(x: 0.1, y: 0.1)
        let b = NormalizedPoint(x: 0.5, y: 0.5)
        let c = NormalizedPoint(x: 0.9, y: 0.9)
        let events = InputEventPlanner.plan(.drag(start: a, waypoints: [b, c], modifiers: 0), windowID: w)
        XCTAssertEqual(events.map { $0.eventKind }, [.mouseDown, .mouseDrag, .mouseUp])
        XCTAssertEqual(events[0].point, a)
        XCTAssertEqual(events[1].point, b) // intermediate → drag
        XCTAssertEqual(events[2].point, c) // last → up (release)
    }

    func testDragWithNoWaypointsReleasesAtStart() {
        let a = NormalizedPoint(x: 0.2, y: 0.3)
        let events = InputEventPlanner.plan(.drag(start: a, waypoints: [], modifiers: 0), windowID: w)
        XCTAssertEqual(events.map { $0.eventKind }, [.mouseDown, .mouseUp])
        XCTAssertTrue(events.allSatisfy { $0.point == a })
    }

    func testMoveIsSingleMouseMove() {
        let events = InputEventPlanner.plan(.move(p), windowID: w)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventKind, .mouseMove)
    }

    func testScrollCarriesDeltas() {
        let events = InputEventPlanner.plan(.scroll(p, dx: 3, dy: -5), windowID: w)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventKind, .scroll)
        XCTAssertEqual(events[0].scrollDX, 3)
        XCTAssertEqual(events[0].scrollDY, -5)
    }

    func testKeyIsDownThenUp() {
        let events = InputEventPlanner.plan(.key(code: 4, modifiers: 0x200), windowID: w)
        XCTAssertEqual(events.map { $0.eventKind }, [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.keyCode == 4 && $0.modifiers == 0x200 })
    }

    // MARK: - Text chunking

    func testShortTextIsOneEvent() {
        let events = InputEventPlanner.plan(.type("hello"), windowID: w)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].text, "hello")
    }

    func testEmptyTextIsNoEvents() {
        XCTAssertTrue(InputEventPlanner.plan(.type(""), windowID: w).isEmpty)
    }

    func testLongTextChunksAndReassembles() {
        let text = String(repeating: "x", count: 550) // > 200×2
        let events = InputEventPlanner.plan(.type(text), windowID: w)
        XCTAssertEqual(events.count, 3) // 200 + 200 + 150
        XCTAssertEqual(events.compactMap { $0.text }.joined(), text)
    }

    func testChunkNeverSplitsGraphemeCluster() {
        // 3 flag emoji (each is a multi-scalar grapheme); chunk size 1 → 3 chunks, each one flag.
        let flags = "🇺🇸🇯🇵🇬🇧"
        let chunks = InputEventPlanner.chunk(flags, size: 1)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined(), flags)
        // Each chunk is exactly one grapheme (round-trips as a valid flag).
        XCTAssertTrue(chunks.allSatisfy { $0.count == 1 })
    }
}
