import XCTest
@testable import JoeScreenKit

final class RoomModelControllerTests: XCTestCase {

    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()

    func testSetControllerAndQuery() {
        var room = RoomModel()
        let owner = ParticipantID(); let driver = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        XCTAssertNil(room.controller(of: w))
        XCTAssertTrue(room.setController(driver, window: w))
        XCTAssertEqual(room.controller(of: w), driver)
    }

    func testSetControllerNoBumpWhenUnchanged() {
        var room = RoomModel()
        let w = WindowID(); room.addShare(w, owner: ParticipantID())
        let driver = ParticipantID()
        room.setController(driver, window: w)
        let rev = room.revision
        XCTAssertFalse(room.setController(driver, window: w))
        XCTAssertEqual(room.revision, rev)
    }

    func testClearControllerWithNil() {
        var room = RoomModel()
        let w = WindowID(); room.addShare(w, owner: ParticipantID())
        room.setController(ParticipantID(), window: w)
        XCTAssertTrue(room.setController(nil, window: w))
        XCTAssertNil(room.controller(of: w))
    }

    func testSetControllerFailsForUnknownWindow() {
        var room = RoomModel()
        XCTAssertFalse(room.setController(ParticipantID(), window: WindowID()))
    }

    func testRemoveShareClearsController() {
        var room = RoomModel()
        let w = WindowID(); room.addShare(w, owner: ParticipantID())
        room.setController(ParticipantID(), window: w)
        room.removeShare(w)
        XCTAssertNil(room.controller(of: w))
    }

    func testDepartedDriverClearedFromOthersWindows() {
        var room = RoomModel()
        let owner = ParticipantID(); let driver = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setController(driver, window: w)
        // The driver (not the owner) leaves → their driver-ship is cleared, the share stays.
        XCTAssertTrue(room.removeParticipant(driver))
        XCTAssertNil(room.controller(of: w))
        XCTAssertEqual(room.owner(of: w), owner) // share intact
    }

    func testPruneClearsControllerWithoutBump() {
        var room = RoomModel()
        let owner = ParticipantID(); let driver = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setController(driver, window: w)
        let rev = room.revision
        XCTAssertTrue(room.pruneParticipant(driver))
        XCTAssertNil(room.controller(of: w))
        XCTAssertEqual(room.revision, rev) // receiver-local prune never bumps
    }

    // MARK: - Additive wire back-compat

    func testRoomModelRoundTripWithController() throws {
        var room = RoomModel()
        let owner = ParticipantID(); let driver = ParticipantID(); let w = WindowID()
        room.addShare(w, owner: owner)
        room.setController(driver, window: w)
        let back = try decoder.decode(RoomModel.self, from: try encoder.encode(room))
        XCTAssertEqual(back, room)
        XCTAssertEqual(back.controller(of: w), driver)
    }

    func testDecodesOldSnapshotWithoutControllerKey() throws {
        var room = RoomModel()
        room.addShare(WindowID(), owner: ParticipantID())
        let data = try encoder.encode(room)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "controllerByWindow")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let back = try decoder.decode(RoomModel.self, from: stripped)
        XCTAssertTrue(back.controllerByWindow.isEmpty)
        XCTAssertEqual(back.revision, room.revision)
    }
}
