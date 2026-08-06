import XCTest
@testable import JoeScreenKit

/// Covers the share-state-sync receiver semantics: snapshots UNION-MERGE shares per windowID
/// (revision counters are per-process and collide across concurrent sharers, so the old
/// last-writer-wins gate silently dropped foreign shares — the "window renders but the share
/// isn't in the list" bug), and ShareEvents add/remove shares incrementally on top of merged state.
final class RoomModelMergeTests: XCTestCase {

    // Union merge: shares present on EITHER side survive — ours are kept, theirs are added.
    func testMergeUnionsBothSidesShares() {
        let alice = UUID(), bob = UUID()
        let winA = UUID(), winB = UUID()
        var local = RoomModel()
        local.addShare(winA, owner: alice)

        var foreign = RoomModel()
        foreign.addShare(winB, owner: bob)

        XCTAssertTrue(local.merge(snapshot: foreign), "merge with new shares reports a change")
        XCTAssertEqual(local.owner(of: winA), alice, "local share survives the merge")
        XCTAssertEqual(local.owner(of: winB), bob, "foreign share is added by the merge")
        XCTAssertEqual(local.shares.count, 2)
    }

    // Revision collision: two peers sharing concurrently bump their per-process revisions to the
    // same value. The old gate (`foreign.revision > local.revision`) dropped that snapshot; the
    // union merge applies it regardless of revision.
    func testMergeAppliesSnapshotDespiteRevisionCollision() {
        let alice = UUID(), bob = UUID()
        let winA = UUID(), winB = UUID()
        var local = RoomModel()
        local.addShare(winA, owner: alice)   // local revision now 1

        var foreign = RoomModel()
        foreign.addShare(winB, owner: bob)   // foreign revision also 1 — collision
        XCTAssertEqual(local.revision, foreign.revision, "setup: per-process revisions collide")
        XCTAssertFalse(foreign.revision > local.revision, "the old gate would drop this snapshot")

        local.merge(snapshot: foreign)
        XCTAssertEqual(local.owner(of: winB), bob, "foreign share survives the revision collision")
    }

    // Snapshots never remove: a share absent from an incoming (stale) snapshot survives locally —
    // unshares travel as ordered ShareEvents, not via snapshots.
    func testMergeNeverRemovesSharesAbsentFromSnapshot() {
        let alice = UUID(), bob = UUID()
        let winA = UUID(), winB = UUID()
        var local = RoomModel()
        local.addShare(winA, owner: alice)
        local.addShare(winB, owner: bob)

        var foreign = RoomModel()
        foreign.addShare(winA, owner: alice) // snapshot that doesn't know about winB

        let revisionBefore = local.revision
        XCTAssertFalse(local.merge(snapshot: foreign), "a merge that changes nothing reports no change")
        XCTAssertEqual(local.owner(of: winB), bob, "a share absent from the snapshot survives")
        XCTAssertEqual(local.revision, revisionBefore, "no-op merge doesn't bump the revision")
    }

    // The local participant is authoritative for its own shares: a stale foreign mirror that still
    // lists MY share must not resurrect it after I unshared (excludingOwner:).
    func testMergeExcludesSharesOwnedByLocalParticipant() {
        let me = UUID(), henry = UUID()
        let myWin = UUID(), henryWin = UUID()
        var room = RoomModel()
        room.addShare(myWin, owner: me)
        room.removeShare(myWin) // I unshared

        var foreign = RoomModel()
        foreign.addShare(myWin, owner: me)      // stale mirror still lists my share
        foreign.addShare(henryWin, owner: henry)

        room.merge(snapshot: foreign, excludingOwner: me)
        XCTAssertNil(room.owner(of: myWin), "my unshared share is NOT resurrected by a stale mirror")
        XCTAssertEqual(room.owner(of: henryWin), henry, "others' shares still merge in")
    }

    // Pause updates keep flowing through snapshots for shares both sides know.
    func testMergeAdoptsPauseStateForKnownShares() {
        let owner = UUID(), win = UUID()
        var room = RoomModel()
        room.addShare(win, owner: owner)

        var foreign = RoomModel()
        foreign.addShare(win, owner: owner)
        foreign.setPauseState(.paused, window: win)

        XCTAssertTrue(room.merge(snapshot: foreign), "a pause-state change alone reports a change")
        XCTAssertEqual(room.pauseState(of: win), .paused, "known share adopts the snapshot's pause state")
    }

    // ShareEvent `.shared` is applied incrementally: the share + its owner land in room state even
    // without any snapshot (previously receivers ignored `.shared` and the list stayed empty).
    func testShareEventSharedAddsShareIncrementally() {
        let owner = UUID(), win = UUID()
        var room = RoomModel()
        let ev = ShareEvent(action: .shared, windowID: win, ownerID: owner, revision: 1)

        XCTAssertEqual(ev.action, .shared)
        XCTAssertTrue(room.addShare(ev.windowID, owner: ev.ownerID))
        XCTAssertEqual(room.owner(of: win), owner, "share list reflects the shared event")
        XCTAssertEqual(room.pauseState(of: win), .live, "a new share defaults to live")
    }

    // ShareEvent `.unshared` is applied incrementally: the share and all state hanging off it
    // disappear.
    func testShareEventUnsharedRemovesShareIncrementally() {
        let owner = UUID(), win = UUID()
        var room = RoomModel()
        room.addShare(win, owner: owner)
        room.setPauseState(.paused, window: win)

        let ev = ShareEvent(action: .unshared, windowID: win, ownerID: owner, revision: 3)
        XCTAssertTrue(room.removeShare(ev.windowID))
        XCTAssertNil(room.owner(of: win), "share list no longer contains the unshared window")
        XCTAssertNil(room.pauseState(of: win), "pause state is cleaned up with the share")
    }

    // End-to-end shape of the reported bug: Henry's track subscribes (his share is added from the
    // publisher identity), THEN his snapshot arrives with a colliding revision — the share must
    // still be listed, exactly once, with the same owner.
    func testTrackDerivedSharePlusCollidingSnapshotListsShareOnce() {
        let henry = UUID(), henryWin = UUID()
        var room = RoomModel()
        // Track subscription path: share recorded from the publisher's identity.
        XCTAssertTrue(room.addShare(henryWin, owner: henry))

        // Henry's snapshot arrives; his per-process revision (1) does not exceed ours (1).
        var henrySnapshot = RoomModel()
        henrySnapshot.addShare(henryWin, owner: henry)
        XCTAssertFalse(henrySnapshot.revision > room.revision, "the old gate would drop this snapshot")

        XCTAssertFalse(room.merge(snapshot: henrySnapshot), "re-merging the same share is a no-op")
        XCTAssertEqual(room.owner(of: henryWin), henry, "Henry's share stays listed")
        XCTAssertEqual(room.shares.count, 1, "the share appears exactly once")
    }
}
