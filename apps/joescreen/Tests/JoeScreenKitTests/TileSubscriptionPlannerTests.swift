import XCTest
@testable import JoeScreenKit

final class TileSubscriptionPlannerTests: XCTestCase {

    private func plan(
        selfID: ParticipantID?,
        remotes: [ParticipantID],
        names: [ParticipantID: String] = [:],
        cameras: Set<ParticipantID> = [],
        sharesDecoded: Int = 0,
        budget: Int = 6
    ) -> [TileSubscriptionPlanner.Tile] {
        TileSubscriptionPlanner.plan(
            selfID: selfID, remotes: remotes,
            displayName: { names[$0] }, hasRenderableCamera: { cameras.contains($0) },
            sharesDecoded: sharesDecoded, maxDecodedStreams: budget)
    }

    func testSelfTileFirst() {
        let me = ParticipantID(), other = ParticipantID()
        let tiles = plan(selfID: me, remotes: [other])
        XCTAssertEqual(tiles.first?.participant, me)
        XCTAssertTrue(tiles.first?.isSelf == true)
    }

    func testOrderingByNameThenUUID() {
        let me = ParticipantID()
        let a = ParticipantID(), b = ParticipantID(), c = ParticipantID()
        let names = [a: "Charlie", b: "alice", c: "Bob"]
        let tiles = plan(selfID: me, remotes: [a, b, c], names: names)
        // Case-insensitive: alice < Bob < Charlie.
        XCTAssertEqual(tiles.map { $0.participant }, [me, b, c, a])
    }

    func testOrderingDeterministicAcrossInputPermutations() {
        let me = ParticipantID()
        let a = ParticipantID(), b = ParticipantID(), c = ParticipantID()
        let names = [a: "x", b: "x", c: "x"] // same name → UUID tiebreak
        let t1 = plan(selfID: me, remotes: [a, b, c], names: names).map { $0.participant }
        let t2 = plan(selfID: me, remotes: [c, a, b], names: names).map { $0.participant }
        let t3 = plan(selfID: me, remotes: [b, c, a], names: names).map { $0.participant }
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(t2, t3)
        // The remotes are in UUID order after self.
        let expectedRemotes = [a, b, c].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(Array(t1.dropFirst()), expectedRemotes)
    }

    func testNoSelfIDStillPlansRemotes() {
        let a = ParticipantID()
        let tiles = plan(selfID: nil, remotes: [a])
        XCTAssertEqual(tiles.count, 1)
        XCTAssertFalse(tiles[0].isSelf)
    }

    // MARK: - Decode budget

    func testAllCamerasWithinBudgetDecode() {
        let me = ParticipantID()
        let remotes = (0..<3).map { _ in ParticipantID() }
        let tiles = plan(selfID: me, remotes: remotes, cameras: Set(remotes), budget: 6)
        // Self decodes (local); all 3 remote cameras within budget.
        XCTAssertTrue(tiles.filter { !$0.isSelf }.allSatisfy { $0.decoded })
    }

    func testCamerasBeyondBudgetParkAsAvatars() {
        let me = ParticipantID()
        let remotes = (0..<8).map { _ in ParticipantID() }
        let tiles = plan(selfID: me, remotes: remotes, cameras: Set(remotes), sharesDecoded: 0, budget: 6)
        let decodedRemotes = tiles.filter { !$0.isSelf && $0.decoded }.count
        let parkedRemotes = tiles.filter { !$0.isSelf && !$0.decoded }.count
        XCTAssertEqual(decodedRemotes, 6) // budget
        XCTAssertEqual(parkedRemotes, 2)  // the rest park as avatars
    }

    func testSharesTakePriorityOverCameras() {
        let me = ParticipantID()
        let remotes = (0..<6).map { _ in ParticipantID() }
        // 4 share windows already decoded → only 2 camera slots remain.
        let tiles = plan(selfID: me, remotes: remotes, cameras: Set(remotes), sharesDecoded: 4, budget: 6)
        XCTAssertEqual(tiles.filter { !$0.isSelf && $0.decoded }.count, 2)
        XCTAssertEqual(tiles.filter { !$0.isSelf && !$0.decoded }.count, 4)
    }

    func testParticipantsWithoutCameraNeverConsumeBudget() {
        let me = ParticipantID()
        let withCam = (0..<2).map { _ in ParticipantID() }
        let noCam = (0..<10).map { _ in ParticipantID() }
        let tiles = plan(selfID: me, remotes: withCam + noCam, cameras: Set(withCam), budget: 6)
        // Both camera peers decode; the 10 camera-less peers are decoded==false but consumed nothing.
        XCTAssertEqual(tiles.filter { withCam.contains($0.participant) }.filter { $0.decoded }.count, 2)
        XCTAssertTrue(tiles.filter { noCam.contains($0.participant) }.allSatisfy { !$0.decoded })
    }

    func testSharesExceedingBudgetLeaveNoCameraSlots() {
        let me = ParticipantID()
        let remotes = (0..<3).map { _ in ParticipantID() }
        let tiles = plan(selfID: me, remotes: remotes, cameras: Set(remotes), sharesDecoded: 10, budget: 6)
        XCTAssertTrue(tiles.filter { !$0.isSelf }.allSatisfy { !$0.decoded })
    }
}
