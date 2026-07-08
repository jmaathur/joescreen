import XCTest
@testable import JoeScreenKit

/// M7 machine gate: the pure session-coordination model against a `FakeSessionProvider` +
/// bootstrap/snapshot wire round-trips. The GroupActivities runtime rows are hardware (2 devices,
/// different iCloud accounts) and stay PENDING in TESTING.md.
final class SessionCoordinationTests: XCTestCase {

    // TransportBootstrap round-trips (the media-plane bootstrap SharePlay carries).
    func testBootstrapRoundTrip() throws {
        let boot = TransportBootstrap(
            serverURL: URL(string: "wss://sfu.example.com")!, roomName: "team-standup", jwt: "eyJhbGc.payload.sig")
        let bytes = try CoordinationMessage.bootstrap(boot).encoded()
        // Well under the ≤200 KB messenger budget (landmine #1).
        XCTAssertLessThan(bytes.count, 200_000)
        guard case .bootstrap(let back) = try CoordinationMessage.decode(bytes) else {
            return XCTFail("expected bootstrap")
        }
        XCTAssertEqual(back, boot)
    }

    // Room-snapshot coordination message round-trips (late-joiner re-broadcast, R28).
    func testRoomSnapshotCoordinationRoundTrip() throws {
        var model = RoomModel()
        let owner = UUID(), win = UUID()
        model.addShare(win, owner: owner)
        let bytes = try CoordinationMessage.roomSnapshot(model).encoded()
        guard case .roomSnapshot(let back) = try CoordinationMessage.decode(bytes) else {
            return XCTFail("expected roomSnapshot")
        }
        XCTAssertEqual(back, model)
        XCTAssertEqual(back.owner(of: win), owner)
    }

    // FakeSessionProvider: start transitions idle → activating → joined and includes local.
    func testFakeProviderStartJoins() async throws {
        let me = UUID()
        let provider = FakeSessionProvider(localParticipantID: me)
        let activity = JoeScreenActivity(info: .init(sessionName: "S", hostDisplayName: "H"))
        try await provider.start(activity)
        let state = await provider.currentState
        XCTAssertEqual(state, .joined)
        let local = await provider.localParticipantID
        XCTAssertEqual(local, me)
        let participants = await provider.currentParticipants
        XCTAssertTrue(participants.contains(me), "active set includes local (GroupSession semantics)")
    }

    // FakeSessionProvider: a failed activation throws and stays out of `.joined`.
    func testFakeProviderStartFailure() async {
        struct Declined: Error {}
        let provider = FakeSessionProvider(startError: Declined())
        let activity = JoeScreenActivity(info: .init(sessionName: "S", hostDisplayName: "H"))
        do {
            try await provider.start(activity)
            XCTFail("start should have thrown")
        } catch {
            let state = await provider.currentState
            XCTAssertEqual(state, .idle)
            let local = await provider.localParticipantID
            XCTAssertNil(local)
        }
    }

    // FakeSessionProvider: participant stream reflects joins/leaves + invalidation.
    func testFakeProviderParticipantAndStateStreams() async throws {
        let me = UUID(), peer = UUID()
        let provider = FakeSessionProvider(localParticipantID: me)
        try await provider.start(JoeScreenActivity(info: .init(sessionName: "S", hostDisplayName: "H")))

        await provider.simulateParticipantJoined(peer)
        var participants = await provider.currentParticipants
        XCTAssertEqual(participants, [me, peer])

        await provider.simulateParticipantLeft(peer)
        participants = await provider.currentParticipants
        XCTAssertEqual(participants, [me])

        // Invalidation transitions to .invalidated (R28 — media survives, coordination dies).
        await provider.simulateInvalidated()
        let state = await provider.currentState
        XCTAssertEqual(state, .invalidated)
    }

    // The coordinator's bootstrap must fit the SignalingSendQueue (never exceeds its per-message cap).
    func testBootstrapFitsSignalingQueue() throws {
        let boot = TransportBootstrap(
            serverURL: URL(string: "wss://sfu.example.com:443")!, roomName: String(repeating: "r", count: 200), jwt: String(repeating: "j", count: 2000))
        let bytes = try CoordinationMessage.bootstrap(boot).encoded()
        var queue = SignalingSendQueue()
        // enqueue must not throw tooLarge for a realistic bootstrap.
        XCTAssertNoThrow(try queue.enqueue(bytes, now: 0))
        XCTAssertEqual(queue.depth, 1)
    }
}
