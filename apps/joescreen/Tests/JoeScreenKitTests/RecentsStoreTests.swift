import XCTest
@testable import JoeScreenKit

final class RecentsStoreTests: XCTestCase {
    private func entry(_ server: String, _ room: String, _ name: String? = nil) -> RecentsStore.Entry {
        RecentsStore.Entry(serverURL: server, room: room, displayName: name)
    }

    func testRecordPrependsMostRecent() {
        var s = RecentsStore()
        s.record(entry("ws://a", "r1"))
        s.record(entry("ws://a", "r2"))
        XCTAssertEqual(s.entries.map { $0.room }, ["r2", "r1"])
    }

    func testRejoinMovesToFrontAndUpdatesName() {
        var s = RecentsStore()
        s.record(entry("ws://a", "r1", "Ada"))
        s.record(entry("ws://a", "r2"))
        s.record(entry("ws://a", "r1", "Ada Lovelace")) // rejoin r1
        XCTAssertEqual(s.entries.map { $0.room }, ["r1", "r2"])
        XCTAssertEqual(s.entries.first?.displayName, "Ada Lovelace") // name updated
        XCTAssertEqual(s.entries.count, 2) // no duplicate
    }

    func testDedupIsByServerAndRoomNotIdentity() {
        var s = RecentsStore()
        // Same server+room recorded twice (different join sessions) → one entry.
        s.record(entry("ws://a", "demo"))
        s.record(entry("ws://a", "demo"))
        XCTAssertEqual(s.entries.count, 1)
        // Different server, same room → distinct.
        s.record(entry("ws://b", "demo"))
        XCTAssertEqual(s.entries.count, 2)
    }

    func testCapEvictsOldest() {
        var s = RecentsStore(maxEntries: 3)
        for i in 1...5 { s.record(entry("ws://a", "r\(i)")) }
        XCTAssertEqual(s.entries.map { $0.room }, ["r5", "r4", "r3"]) // oldest (r1, r2) evicted
    }

    func testRemoveAndClear() {
        var s = RecentsStore()
        s.record(entry("ws://a", "r1"))
        s.record(entry("ws://a", "r2"))
        s.remove(key: entry("ws://a", "r1").key)
        XCTAssertEqual(s.entries.map { $0.room }, ["r2"])
        s.clear()
        XCTAssertTrue(s.entries.isEmpty)
    }

    func testCodableRoundTrip() throws {
        var s = RecentsStore(maxEntries: 4)
        s.record(entry("ws://a", "r1", "Ada"))
        s.record(entry("ws://b", "r2"))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(RecentsStore.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testConstructorEnforcesDedupAndCap() {
        // A decoded blob with dupes/overflow is normalized on construction.
        let s = RecentsStore(entries: [
            entry("ws://a", "r1"), entry("ws://a", "r1"), entry("ws://a", "r2"), entry("ws://a", "r3"),
        ], maxEntries: 2)
        XCTAssertEqual(s.entries.map { $0.room }, ["r1", "r2"])
    }
}
