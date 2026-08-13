import XCTest
@testable import JoeScreenKit

final class CallEndDetectorTests: XCTestCase {
    func testInitialDisconnectedSeedDoesNotEndCall() {
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.disconnected))
        XCTAssertFalse(detector.observeConnection(.connecting))
    }

    func testDisconnectAfterConnectionEndsCallExactlyOnce() {
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertTrue(detector.observeConnection(.disconnected))
        XCTAssertFalse(detector.observeConnection(.disconnected))
    }

    func testReconnectInProgressDoesNotEndCall() {
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertFalse(detector.observeConnection(.reconnecting))
        XCTAssertFalse(detector.observeConnection(.connected))
    }

    func testEmptyRosterDuringReconnectDoesNotReportCallEnd() {
        let local = ParticipantID()
        let remote = ParticipantID()
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertFalse(detector.observeParticipants([local, remote], localParticipantID: local))
        XCTAssertFalse(detector.observeConnection(.reconnecting))
        XCTAssertFalse(detector.observeParticipants([local], localParticipantID: local))
        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertTrue(detector.observeParticipants([local], localParticipantID: local))
    }

    func testTerminalFailureAfterConnectionEndsCall() {
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertTrue(detector.observeConnection(.failed(reason: "server closed")))
    }

    func testFailureBeforeConnectionDoesNotReportEndedCall() {
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connecting))
        XCTAssertFalse(detector.observeConnection(.failed(reason: "could not connect")))
    }

    func testInitiallyEmptyRoomDoesNotReportDepartureUntilRemoteParticipantComesAndGoes() {
        let local = ParticipantID()
        let remote = ParticipantID()
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertFalse(detector.observeParticipants([local], localParticipantID: local))
        XCTAssertFalse(detector.observeParticipants([local, remote], localParticipantID: local))
        XCTAssertTrue(detector.observeParticipants([local], localParticipantID: local))
        XCTAssertFalse(detector.observeParticipants([local], localParticipantID: local))
    }

    func testRemoteParticipantReturningRearmsDepartureReport() {
        let local = ParticipantID()
        let remote = ParticipantID()
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertFalse(detector.observeParticipants([local, remote], localParticipantID: local))
        XCTAssertTrue(detector.observeParticipants([local], localParticipantID: local))
        XCTAssertFalse(detector.observeParticipants([local, remote], localParticipantID: local))
        XCTAssertTrue(detector.observeParticipants([local], localParticipantID: local))
    }

    func testReconnectRearmsDepartureReportForAuthoritativeRosterSeed() {
        let local = ParticipantID()
        let remote = ParticipantID()
        var detector = CallEndDetector()

        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertFalse(detector.observeParticipants([local, remote], localParticipantID: local))
        XCTAssertTrue(detector.observeParticipants([local], localParticipantID: local))

        // The grace-period confirmation cannot conclude while reconnecting. Once LiveKit connects
        // again it re-seeds its current roster, which must be allowed to report the still-empty call.
        XCTAssertFalse(detector.observeConnection(.reconnecting))
        XCTAssertFalse(detector.observeParticipants([local], localParticipantID: local))
        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertTrue(detector.observeParticipants([local], localParticipantID: local))
    }

    func testResetAllowsDetectorToBeReusedForNextCall() {
        var detector = CallEndDetector()
        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertTrue(detector.observeConnection(.disconnected))

        detector.reset()

        XCTAssertFalse(detector.observeConnection(.disconnected))
        XCTAssertFalse(detector.observeConnection(.connected))
        XCTAssertTrue(detector.observeConnection(.disconnected))
    }
}
