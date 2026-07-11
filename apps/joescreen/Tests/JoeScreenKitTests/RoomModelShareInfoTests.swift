import XCTest
@testable import JoeScreenKit

final class RoomModelShareInfoTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - setShareInfo

    func testSetShareInfoBumpsOnceAndStores() {
        var room = RoomModel()
        let owner = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        let revAfterShare = room.revision
        let info = ShareInfo(kind: .window, title: "T", appName: "Xcode",
                             sourcePixelWidth: 2880, sourcePixelHeight: 1800)
        XCTAssertTrue(room.setShareInfo(info, window: w))
        XCTAssertEqual(room.revision, revAfterShare + 1)
        XCTAssertEqual(room.info(of: w), info)
    }

    func testSetShareInfoNoBumpWhenUnchanged() {
        var room = RoomModel()
        let w = WindowID(); room.addShare(w, owner: ParticipantID())
        let info = ShareInfo(kind: .window, title: "T")
        room.setShareInfo(info, window: w)
        let rev = room.revision
        XCTAssertFalse(room.setShareInfo(info, window: w)) // identical → no change
        XCTAssertEqual(room.revision, rev)
    }

    func testSetShareInfoFailsForUnknownWindow() {
        var room = RoomModel()
        XCTAssertFalse(room.setShareInfo(ShareInfo(kind: .window), window: WindowID()))
        XCTAssertEqual(room.revision, 0)
    }

    func testRemoveShareCascadeClearsShareInfo() {
        var room = RoomModel()
        let w = WindowID(); room.addShare(w, owner: ParticipantID())
        room.setShareInfo(ShareInfo(kind: .window, title: "T"), window: w)
        XCTAssertNotNil(room.info(of: w))
        room.removeShare(w)
        XCTAssertNil(room.info(of: w))
    }

    func testRemoveParticipantCascadeClearsShareInfoAndBumps() {
        var room = RoomModel()
        let owner = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setShareInfo(ShareInfo(kind: .window, title: "T"), window: w)
        let rev = room.revision
        XCTAssertTrue(room.removeParticipant(owner))
        XCTAssertNil(room.info(of: w))
        XCTAssertNil(room.owner(of: w))
        XCTAssertEqual(room.revision, rev + 1) // host-side prune bumps
    }

    // MARK: - pruneParticipant (receiver-side, NEVER bumps)

    func testPruneParticipantDoesNotBumpRevision() {
        var room = RoomModel()
        let owner = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setShareInfo(ShareInfo(kind: .window, title: "T"), window: w)
        let rev = room.revision
        XCTAssertTrue(room.pruneParticipant(owner))
        // State cleaned up …
        XCTAssertNil(room.owner(of: w))
        XCTAssertNil(room.info(of: w))
        // … but revision UNCHANGED (receiver-local bump would corrupt host LWW ordering).
        XCTAssertEqual(room.revision, rev)
    }

    func testPruneUnknownParticipantIsNoChangeNoBump() {
        var room = RoomModel()
        room.addShare(WindowID(), owner: ParticipantID())
        let rev = room.revision
        XCTAssertFalse(room.pruneParticipant(ParticipantID()))
        XCTAssertEqual(room.revision, rev)
    }

    func testPruneAlsoClearsPresenceOnOthersWindows() {
        var room = RoomModel()
        let sharer = ParticipantID(); let controller = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: sharer)
        room.setControlMode(.control, participant: controller, window: w)
        room.setWriteAccess(true, participant: controller, window: w)
        let rev = room.revision
        XCTAssertTrue(room.pruneParticipant(controller))
        XCTAssertEqual(room.controlMode(of: controller, in: w), .watch)
        XCTAssertFalse(room.hasWriteAccess(controller, in: w))
        XCTAssertEqual(room.revision, rev) // still no bump
    }

    // MARK: - Old ↔ new RoomSnapshot decode matrix (additive wire rule)

    func testRoomModelRoundTripWithShareInfo() throws {
        var room = RoomModel()
        let owner = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setShareInfo(ShareInfo(kind: .display, title: "Display 1",
                                    sourcePixelWidth: 2560, sourcePixelHeight: 1600), window: w)
        let data = try encoder.encode(room)
        let back = try decoder.decode(RoomModel.self, from: data)
        XCTAssertEqual(back, room)
        XCTAssertEqual(back.info(of: w), room.info(of: w))
    }

    func testDecodesOldSnapshotWithoutShareInfoKey() throws {
        // Simulate a peer that predates `shareInfo`: encode a room, strip the key from the JSON,
        // and confirm it still decodes (to an empty shareInfo) rather than throwing.
        var room = RoomModel()
        room.addShare(WindowID(), owner: ParticipantID())
        let data = try encoder.encode(room)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "shareInfo")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let back = try decoder.decode(RoomModel.self, from: stripped)
        XCTAssertTrue(back.shareInfo.isEmpty)
        XCTAssertEqual(back.shares.count, 1)
        XCTAssertEqual(back.revision, room.revision)
    }

    func testRoomSnapshotWireRoundTripCarriesShareInfo() throws {
        var room = RoomModel()
        let owner = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setShareInfo(ShareInfo(kind: .window, title: "main.swift", appName: "Xcode",
                                    sourcePixelWidth: 1600, sourcePixelHeight: 1000), window: w)
        let env = try WireCodec.pack(RoomSnapshot(model: room), sender: owner)
        let bytes = try WireCodec.encode(env)
        let decodedEnv = try WireCodec.decode(bytes)
        let snap = try WireCodec.unpack(decodedEnv, as: RoomSnapshot.self)
        XCTAssertEqual(snap.model.info(of: w)?.title, "main.swift")
        XCTAssertEqual(snap.model.info(of: w)?.sourceAspectRatio, 1.6)
    }

    // MARK: - ShareEvent.info back-compat

    func testShareEventWithInfoRoundTrips() throws {
        let ev = ShareEvent(action: .shared, windowID: WindowID(), ownerID: ParticipantID(),
                            revision: 3, info: ShareInfo(kind: .window, title: "T"))
        let data = try encoder.encode(ev)
        XCTAssertEqual(try decoder.decode(ShareEvent.self, from: data), ev)
    }

    func testShareEventDecodesOldPayloadWithoutInfo() throws {
        // Old peer sent a ShareEvent with no `info` key at all → decodes to info == nil, no throw.
        let owner = ParticipantID(); let w = WindowID()
        let json = """
        {"action":"shared","windowID":"\(w.uuidString)","ownerID":"\(owner.uuidString)","revision":2}
        """.data(using: .utf8)!
        let ev = try decoder.decode(ShareEvent.self, from: json)
        XCTAssertEqual(ev.action, .shared)
        XCTAssertNil(ev.info)
    }

    func testUnsharedShareEventHasNilInfoByDefault() {
        let ev = ShareEvent(action: .unshared, windowID: WindowID(), ownerID: ParticipantID(), revision: 5)
        XCTAssertNil(ev.info)
    }
}
