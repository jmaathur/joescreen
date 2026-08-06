import XCTest
import Foundation
@testable import JoeScreenLiveKit

/// Pure-logic tests for the display-name additions to the dev JWT (no SFU needed — runs offline):
/// the `name` claim carries the display name so peers see it from the join itself, and the
/// `canUpdateOwnMetadata` grant lets the client repair/publish its name after connect via
/// `LocalParticipant.set(name:)` / `set(metadata:)`.
final class DevTokenMinterTests: XCTestCase {

    /// Decode the claims segment (segment 2) of a JWT produced by `DevTokenMinter.mint`.
    private func claims(of token: String) throws -> [String: Any] {
        let segments = token.split(separator: ".")
        XCTAssertEqual(segments.count, 3, "JWT must have header.claims.signature")
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        let data = try XCTUnwrap(Data(base64Encoded: base64), "claims segment must be base64url")
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any], "claims must be a JSON object")
    }

    func testNameClaimPresentWhenProvided() throws {
        let token = DevTokenMinter.mint(identity: UUID().uuidString, room: "demo", name: "Joe Blau")
        let claims = try claims(of: token)
        XCTAssertEqual(claims["name"] as? String, "Joe Blau")
    }

    func testNameClaimOmittedWhenNil() throws {
        // Back-compat: existing call sites (and older peers) mint without a name — no claim.
        let token = DevTokenMinter.mint(identity: UUID().uuidString, room: "demo")
        let claims = try claims(of: token)
        XCTAssertNil(claims["name"])
    }

    func testNameClaimOmittedWhenEmpty() throws {
        let token = DevTokenMinter.mint(identity: UUID().uuidString, room: "demo", name: "")
        let claims = try claims(of: token)
        XCTAssertNil(claims["name"])
    }

    func testVideoGrantAllowsUpdatingOwnMetadata() throws {
        let token = DevTokenMinter.mint(identity: UUID().uuidString, room: "demo")
        let claims = try claims(of: token)
        let video = try XCTUnwrap(claims["video"] as? [String: Any])
        XCTAssertEqual(video["canUpdateOwnMetadata"] as? Bool, true)
        // The pre-existing grant shape must be untouched.
        XCTAssertEqual(video["room"] as? String, "demo")
        XCTAssertEqual(video["roomJoin"] as? Bool, true)
        XCTAssertEqual(video["canPublish"] as? Bool, true)
        XCTAssertEqual(video["canSubscribe"] as? Bool, true)
        XCTAssertEqual(video["canPublishData"] as? Bool, true)
    }

    func testIdentityAndRoomStillLandInClaims() throws {
        let identity = UUID().uuidString
        let token = DevTokenMinter.mint(identity: identity, room: "demo", name: "Joe")
        let claims = try claims(of: token)
        XCTAssertEqual(claims["sub"] as? String, identity)
        XCTAssertEqual(claims["iss"] as? String, DevTokenMinter.devAPIKey)
    }
}
