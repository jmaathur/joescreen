import XCTest
import Foundation
import LiveKit
@testable import JoeScreenLiveKit
@testable import JoeScreenKit

/// Proves the participant-roster surface that fixes "I only see myself in Participants": two clients
/// in the same room must each see BOTH identities via `currentParticipantIDs()` — independent of
/// whether anyone has shared a window (the old roster was derived only from share owners, so a
/// non-sharing peer, and often yourself, never appeared). Skips unless `LIVEKIT_URL` is set.
final class ParticipantRosterTests: XCTestCase {

    private func serverURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["LIVEKIT_URL"], let url = URL(string: raw) else {
            throw XCTSkip("LIVEKIT_URL not set — skipping participant-roster test (offline gate).")
        }
        return url
    }

    private func token(identity: String, room: String) -> String {
        DevTokenMinter.mint(identity: identity, room: room)
    }

    func testBothPeersSeeEachOtherWithoutSharing() async throws {
        let url = try serverURL()
        let room = "itest-roster-\(UUID().uuidString.prefix(8))"
        let idA = UUID(), idB = UUID()

        let transportA = LiveKitTransport()
        let transportB = LiveKitTransport()
        defer { Task { await transportA.disconnect(); await transportB.disconnect() } }

        try await transportA.connect(.init(serverURL: url, authToken: token(identity: idA.uuidString, room: room)))
        try await transportB.connect(.init(serverURL: url, authToken: token(identity: idB.uuidString, room: room)))

        // Give the SFU a moment to propagate participant-connected events to A. Poll up to ~5s so a
        // slow event doesn't flake the test.
        var aRoster = Set<ParticipantID>()
        var bRoster = Set<ParticipantID>()
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            aRoster = await transportA.currentParticipantIDs()
            bRoster = await transportB.currentParticipantIDs()
            if aRoster.contains(idB) && bRoster.contains(idA) { break }
        }

        XCTAssertTrue(aRoster.contains(idA), "A must see itself")
        XCTAssertTrue(aRoster.contains(idB), "A must see the other peer B even though nobody shared")
        XCTAssertTrue(bRoster.contains(idB), "B must see itself")
        XCTAssertTrue(bRoster.contains(idA), "B must see the other peer A even though nobody shared")
    }
}
