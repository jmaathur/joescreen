import XCTest
@testable import JoeScreenKit

final class RemoteWindowLifecycleTests: XCTestCase {

    typealias L = RemoteWindowLifecycle

    // MARK: - Happy path

    func testSubscribeOpensExactlyOneWindow() {
        var l = L()
        XCTAssertEqual(l.state, .subscribing)
        XCTAssertEqual(l.reduce(.trackSubscribed), [.openWindow])
        XCTAssertEqual(l.state, .open)
        // A duplicate subscribe must NOT open a second window (the duplicate-window bug).
        XCTAssertEqual(l.reduce(.trackSubscribed), [])
        XCTAssertEqual(l.state, .open)
    }

    // MARK: - Sharer crash / disconnect (frozen-ghost bug)

    func testTrackEndedWhileConnectedPurgesImmediately() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.trackGone(.trackEnded)), [.closeWindow, .purge])
        XCTAssertEqual(l.state, .gone)
        // Terminal: further events are inert.
        XCTAssertEqual(l.reduce(.trackSubscribed), [])
        XCTAssertEqual(l.reduce(.userReopened), [])
    }

    func testTrackEndedWhileReconnectingParksStaleThenPurgesOnGraceExpiry() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.transportReconnecting(true)), [])
        // A blip during reconnect must NOT flap the window — it parks stale (frozen frame).
        XCTAssertEqual(l.reduce(.trackGone(.trackEnded)), [.pauseRendering])
        XCTAssertEqual(l.state, .stale)
        // Grace expires with no recovery → tear down.
        XCTAssertEqual(l.reduce(.graceExpired), [.closeWindow, .purge])
        XCTAssertEqual(l.state, .gone)
    }

    func testTrackReturnsWithinGraceResumesSameWindow() {
        var l = openLifecycle()
        l.reduce(.transportReconnecting(true))
        l.reduce(.trackGone(.trackEnded))
        XCTAssertEqual(l.state, .stale)
        // The track comes back before grace expires → resume the SAME window, no new one.
        XCTAssertEqual(l.reduce(.trackSubscribed), [.resumeRendering])
        XCTAssertEqual(l.state, .open)
    }

    func testSnapshotRemovalPurgesEvenWhileReconnecting() {
        // An authoritative snapshot removal is definitive — no grace park (the share is really gone).
        var l = openLifecycle()
        l.reduce(.transportReconnecting(true))
        XCTAssertEqual(l.reduce(.shareRemovedFromSnapshot), [.closeWindow, .purge])
        XCTAssertEqual(l.state, .gone)
    }

    func testOwnerDisconnectedPurgesEvenWhileReconnecting() {
        var l = openLifecycle()
        l.reduce(.transportReconnecting(true))
        XCTAssertEqual(l.reduce(.ownerDisconnected), [.closeWindow, .purge])
        XCTAssertEqual(l.state, .gone)
    }

    // MARK: - User close / reopen (no duplicate windows, remembered frame)

    func testUserCloseCutsDownlinkAndReopenRoutesNewTrack() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.userClosed), [.closeWindow, .unsubscribe])
        XCTAssertEqual(l.state, .closedByUser)
        // Reopen re-subscribes; the window opens only when the NEW track arrives → one window.
        XCTAssertEqual(l.reduce(.userReopened), [.resubscribe])
        XCTAssertEqual(l.state, .subscribing)
        XCTAssertEqual(l.reduce(.trackSubscribed), [.openWindow])
        XCTAssertEqual(l.state, .open)
    }

    func testTrackGoneWhileClosedByUserPurgesTheStuckEntry() {
        // The user closed it (reopenable entry kept). A REAL trackGone that reaches the reducer means
        // the share genuinely ended (the self-unsubscribe echo is suppressed in the transport, so this
        // isn't that) — the entry is no longer reopenable and must purge, not stick as a "Reopen" tile.
        var l = openLifecycle()
        l.reduce(.userClosed)
        XCTAssertEqual(l.reduce(.trackGone(.trackEnded)), [.purge])
        XCTAssertEqual(l.state, .gone)
    }

    func testOwnerDisconnectWhileClosedByUserPurges() {
        var l = openLifecycle()
        l.reduce(.userClosed)
        XCTAssertEqual(l.reduce(.ownerDisconnected), [.purge])
        XCTAssertEqual(l.state, .gone)
    }

    func testUserCloseWhileSubscribingUnsubscribesOnly() {
        var l = L() // subscribing, no window yet
        XCTAssertEqual(l.reduce(.userClosed), [.unsubscribe])
        XCTAssertEqual(l.state, .closedByUser)
    }

    // MARK: - Soft visibility (miniaturize / occlusion) — R24/R32

    func testMiniaturizeDetachesRendererAndRestoreReattaches() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.miniaturized(true)), [.pauseRendering])
        XCTAssertEqual(l.state, .hidden(.miniaturized))
        XCTAssertEqual(l.reduce(.miniaturized(false)), [.resumeRendering])
        XCTAssertEqual(l.state, .open)
    }

    func testOcclusionDetachesRenderer() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.occluded(true)), [.pauseRendering])
        XCTAssertEqual(l.state, .hidden(.occluded))
    }

    func testOverlappingHideReasonsStayHiddenUntilBothClear() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.miniaturized(true)), [.pauseRendering])
        XCTAssertEqual(l.reduce(.occluded(true)), []) // already hidden; label updates, no effect
        // Clearing only ONE reason keeps it hidden (no premature resume → no wasted downlink).
        XCTAssertEqual(l.reduce(.miniaturized(false)), [])
        XCTAssertEqual(l.state, .hidden(.occluded))
        // Clearing the last reason resumes.
        XCTAssertEqual(l.reduce(.occluded(false)), [.resumeRendering])
        XCTAssertEqual(l.state, .open)
    }

    func testUserCloseFromHiddenClearsVisibilityFlags() {
        var l = openLifecycle()
        l.reduce(.miniaturized(true))
        XCTAssertEqual(l.reduce(.userClosed), [.closeWindow, .unsubscribe])
        XCTAssertEqual(l.state, .closedByUser)
        // Reopen and confirm no stale hidden flag lingers (opens cleanly, then not hidden).
        l.reduce(.userReopened)
        XCTAssertEqual(l.reduce(.trackSubscribed), [.openWindow])
        XCTAssertEqual(l.state, .open)
    }

    func testTrackGoneWhileHiddenPurges() {
        var l = openLifecycle()
        l.reduce(.occluded(true))
        XCTAssertEqual(l.reduce(.trackGone(.trackEnded)), [.closeWindow, .purge])
        XCTAssertEqual(l.state, .gone)
    }

    // MARK: - Visibility churn in non-open states is inert

    func testVisibilityEventsInertWhenClosedOrGone() {
        var closed = openLifecycle(); closed.reduce(.userClosed)
        XCTAssertEqual(closed.reduce(.miniaturized(true)), [])
        XCTAssertEqual(closed.state, .closedByUser)

        var gone = openLifecycle(); gone.reduce(.trackGone(.trackEnded))
        XCTAssertEqual(gone.reduce(.occluded(true)), [])
        XCTAssertEqual(gone.state, .gone)
    }

    // MARK: - Reconnect flag transitions don't spuriously act

    func testReconnectingTrueThenFalseNoEffectOnOpenWindow() {
        var l = openLifecycle()
        XCTAssertEqual(l.reduce(.transportReconnecting(true)), [])
        XCTAssertEqual(l.state, .open)
        XCTAssertEqual(l.reduce(.transportReconnecting(false)), [])
        XCTAssertEqual(l.state, .open)
    }

    func testTrackGoneWhileSubscribingAndReconnectingParksStale() {
        var l = L()
        l.reduce(.transportReconnecting(true))
        XCTAssertEqual(l.reduce(.trackGone(.trackEnded)), [])
        XCTAssertEqual(l.state, .stale)
    }

    // MARK: - Full matrix smoke: every event applied in every state never crashes / stays valid

    func testEveryEventInEveryStateProducesValidState() {
        let events: [L.Event] = [
            .trackSubscribed, .trackGone(.trackEnded), .trackGone(.removedFromSnapshot),
            .trackGone(.ownerDisconnected), .userClosed, .userReopened,
            .miniaturized(true), .miniaturized(false), .occluded(true), .occluded(false),
            .shareRemovedFromSnapshot, .ownerDisconnected,
            .transportReconnecting(true), .transportReconnecting(false), .graceExpired,
        ]
        let seeds: [() -> L] = [
            { L() },                                            // subscribing
            { self.openLifecycle() },                           // open
            { var l = self.openLifecycle(); l.reduce(.userClosed); return l },      // closedByUser
            { var l = self.openLifecycle(); l.reduce(.miniaturized(true)); return l }, // hidden
            { var l = self.openLifecycle(); l.reduce(.transportReconnecting(true)); l.reduce(.trackGone(.trackEnded)); return l }, // stale
            { var l = self.openLifecycle(); l.reduce(.trackGone(.trackEnded)); return l }, // gone
        ]
        let validStates: Set<String> = ["subscribing", "open", "closedByUser", "hidden", "stale", "gone"]
        for seed in seeds {
            for e in events {
                var l = seed()
                _ = l.reduce(e)
                XCTAssertTrue(validStates.contains(tag(l.state)), "invalid state \(l.state) after \(e)")
                // Idempotency guard: a terminal `.gone` never revives to an open/rendering state via
                // a stray subscribe.
                if tag(l.state) == "gone" {
                    XCTAssertTrue(l.reduce(.trackSubscribed).isEmpty)
                    XCTAssertEqual(tag(l.state), "gone")
                }
            }
        }
    }

    // MARK: - Helpers

    private func openLifecycle() -> L {
        var l = L()
        l.reduce(.trackSubscribed)
        return l
    }

    private func tag(_ s: L.State) -> String {
        switch s {
        case .subscribing: return "subscribing"
        case .open: return "open"
        case .closedByUser: return "closedByUser"
        case .hidden: return "hidden"
        case .stale: return "stale"
        case .gone: return "gone"
        }
    }
}
