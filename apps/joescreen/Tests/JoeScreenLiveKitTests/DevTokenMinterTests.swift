import XCTest
import Foundation
@testable import JoeScreenLiveKit

/// DevTokenMinter is DEBUG-only; tests build DEBUG, so it's available. These assert the JWT claim
/// shape WITHOUT a server (pure encode), including the M10 `name` claim.
final class DevTokenMinterTests: XCTestCase {

    /// Decode a JWT's middle (claims) segment into a dictionary.
    private func claims(of jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "a JWT has three dot-separated segments")
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // Re-pad base64url → base64.
        while b64.count % 4 != 0 { b64 += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: b64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNameClaimPresentWhenProvided() throws {
        let jwt = DevTokenMinter.mint(identity: "id-1", room: "r", name: "Ada Lovelace")
        let c = try claims(of: jwt)
        XCTAssertEqual(c["name"] as? String, "Ada Lovelace")
        XCTAssertEqual(c["sub"] as? String, "id-1")
    }

    func testNameClaimOmittedWhenNil() throws {
        let jwt = DevTokenMinter.mint(identity: "id-2", room: "r")
        let c = try claims(of: jwt)
        XCTAssertNil(c["name"], "no name claim when none supplied")
    }

    func testNameClaimOmittedWhenEmpty() throws {
        let jwt = DevTokenMinter.mint(identity: "id-3", room: "r", name: "")
        let c = try claims(of: jwt)
        XCTAssertNil(c["name"], "empty name is treated as no name")
    }

    func testCoreGrantShapeUnchanged() throws {
        // The M10 change must not disturb the existing claim shape.
        let jwt = DevTokenMinter.mint(identity: "id-4", room: "myroom", name: "Bob")
        let c = try claims(of: jwt)
        XCTAssertEqual(c["iss"] as? String, DevTokenMinter.devAPIKey)
        let video = try XCTUnwrap(c["video"] as? [String: Any])
        XCTAssertEqual(video["room"] as? String, "myroom")
        XCTAssertEqual(video["roomJoin"] as? Bool, true)
        XCTAssertEqual(video["canPublish"] as? Bool, true)
        XCTAssertEqual(video["canSubscribe"] as? Bool, true)
        XCTAssertEqual(video["canPublishData"] as? Bool, true)
    }
}
