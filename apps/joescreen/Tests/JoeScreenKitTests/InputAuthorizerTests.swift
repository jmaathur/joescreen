import XCTest
@testable import JoeScreenKit

final class InputAuthorizerTests: XCTestCase {
    let auth = InputAuthorizer()
    let peer = UUID()
    let other = UUID()
    let window = UUID()
    let now = 1000.0

    /// A fully-authorized owner state: control on, window in Control mode, peer holds a write cap.
    private func authorizedState() -> InputAuthorizer.OwnerState {
        var caps = CapabilityStore()
        caps.grant(Capability(participantID: peer, windowID: window, rights: .write))
        return InputAuthorizer.OwnerState(
            remoteControlEnabled: true,
            modeByWindow: [window: .control],
            capabilities: caps,
            locksByWindow: [:],
            ownedWindows: [window]
        )
    }

    private func event() -> InputEvent {
        InputEvent(eventKind: .keyDown, windowID: window, keyCode: 4)
    }

    func testHappyPathInjects() {
        let d = auth.authorize(event: event(), messageSender: peer, transportPeer: peer,
                               state: authorizedState(), now: now)
        XCTAssertEqual(d, .inject)
    }

    func testSpoofedSenderRejected() {
        // messageSender claims `peer` but the DTLS-authenticated transport peer is `other`.
        let d = auth.authorize(event: event(), messageSender: peer, transportPeer: other,
                               state: authorizedState(), now: now)
        XCTAssertEqual(d, .denyPeerIdentityMismatch)
    }

    func testGlobalDisabledDrops() {
        var s = authorizedState(); s.remoteControlEnabled = false
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyGlobalDisabled)
    }

    func testWatchModeDrops() {
        var s = authorizedState(); s.modeByWindow[window] = .watch
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyWatchMode)
    }

    func testDefaultModeIsWatch() {
        var s = authorizedState(); s.modeByWindow = [:] // absent → default watch
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyWatchMode)
    }

    func testNoWriteCapabilityDrops() {
        var s = authorizedState()
        s.capabilities = CapabilityStore() // no grant
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyNoWriteAccess)
    }

    func testExpiredCapabilityDrops() {
        var caps = CapabilityStore()
        caps.grant(Capability(participantID: peer, windowID: window, rights: .write, expiry: now - 1))
        var s = authorizedState(); s.capabilities = caps
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyNoWriteAccess)
    }

    func testUnknownWindowRejected() {
        var s = authorizedState(); s.ownedWindows = [] // owner doesn't own this window
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyUnknownWindow)
    }

    func testSingleActiveControllerLockBlocksOthers() {
        var lock = ActiveControllerLock()
        XCTAssertTrue(lock.take(other))     // someone else is driving
        var s = authorizedState()
        s.locksByWindow[window] = lock
        // `peer` also has a write cap, but `other` holds the lock → peer must wait.
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .denyNotActiveController)
    }

    func testLockHolderCanInject() {
        var lock = ActiveControllerLock()
        XCTAssertTrue(lock.take(peer))
        var s = authorizedState()
        s.locksByWindow[window] = lock
        XCTAssertEqual(auth.authorize(event: event(), messageSender: peer, transportPeer: peer, state: s, now: now),
                       .inject)
    }

    func testLockHandoffIsAtomic() {
        var lock = ActiveControllerLock()
        XCTAssertTrue(lock.take(other))
        XCTAssertFalse(lock.take(peer), "cannot steal a held lock")
        lock.release(other)
        XCTAssertTrue(lock.take(peer), "free after release")
        XCTAssertTrue(lock.isHeld(by: peer))
    }
}
