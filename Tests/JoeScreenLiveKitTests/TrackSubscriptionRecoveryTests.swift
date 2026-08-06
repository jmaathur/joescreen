import XCTest
import Foundation
import LiveKit
@testable import JoeScreenLiveKit
@testable import JoeScreenKit

/// Regression coverage for the join-time subscribe race: a participant who joins AFTER a video
/// track is already live must still receive it. In client-sdk-swift 2.15.1 the engine drops media
/// that arrives before the publication's participant-info update (2 retries × 0.2s, then
/// `didFailToSubscribeTrackWithSid`, which nothing handled), so the track stayed invisible until a
/// re-publish. The transport now retries the subscription with bounded backoff and enumerates
/// publications on `.connected` / participant-join as a fallback.
///
/// Skips unless `LIVEKIT_URL` is set (offline gate). Uses the same device-free synthetic-frame
/// publish as the M2 suite — no camera/mic is opened.
final class TrackSubscriptionRecoveryTests: XCTestCase {

    private func serverURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["LIVEKIT_URL"], let url = URL(string: raw) else {
            throw XCTSkip("LIVEKIT_URL not set — skipping subscription-recovery test (offline gate).")
        }
        return url
    }

    private func token(identity: String, room: String) -> String {
        DevTokenMinter.mint(identity: identity, room: room)
    }

    func testLateJoinerReceivesAlreadyPublishedVideo() async throws {
        let url = try serverURL()
        let room = "itest-latejoin-\(UUID().uuidString.prefix(8))"
        let idA = UUID(), idB = UUID()

        let transportA = LiveKitTransport()
        let transportB = LiveKitTransport()
        defer { Task { await transportA.disconnect(); await transportB.disconnect() } }

        // A connects and starts publishing BEFORE B joins, so B exercises the mid-join path: the
        // track is already live while B's participant-info/media handshake runs.
        try await transportA.connect(.init(serverURL: url, authToken: token(identity: idA.uuidString, room: room)))
        let windowID = UUID()
        let sink = try await transportA.publishVideoTrack(for: windowID)

        // Same feeding discipline as the M2 suite: varying luma keeps the encoder streaming.
        let feeder = Task {
            var tick: UInt8 = 0
            for _ in 0..<600 {
                await sink.submit(LiveKitIntegrationTests.syntheticFrame(luma: tick, timestampNanos: 0))
                tick = tick &+ 7
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        defer { feeder.cancel() }

        // Give A's publish a beat to reach the SFU so the track is unquestionably live pre-join.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // B installs the receive hook, then joins late.
        let received = FrameCountBox()
        await transportB.setOnTrackSubscribed { name, _, track in
            let renderer = CountingRenderer(box: received, trackName: name)
            track.add(videoRenderer: renderer)
            received.retain(renderer) // keep it alive for the test duration
        }
        try await transportB.connect(.init(serverURL: url, authToken: token(identity: idB.uuidString, room: room)))

        let ok = await received.waitForFrames(atLeast: 3, timeout: 20)
        XCTAssertTrue(ok, "late joiner B did not render A's already-live track — join-race regression")
    }
}
