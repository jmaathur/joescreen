import XCTest
@testable import JoeScreenKit

final class SecretRedactorTests: XCTestCase {
    let r = SecretRedactor()

    func testCleanTextUnchanged() {
        let s = "the quick brown fox jumps over the lazy dog"
        XCTAssertEqual(r.redact(s), s)
    }

    func testAWSKeyMasked() {
        let s = "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
        let out = r.redact(s)
        XCTAssertFalse(out.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(out.contains("«redacted»"))
    }

    func testGitHubTokenMasked() {
        let s = "token: ghp_1234567890abcdefABCDEF1234567890abcd"
        let out = r.redact(s)
        XCTAssertFalse(out.contains("ghp_1234567890abcdefABCDEF1234567890abcd"))
    }

    func testKeyValueSecretMasked() {
        let out = r.redact("password=hunter2supersecret")
        XCTAssertFalse(out.contains("hunter2supersecret"))
    }

    func testSSNMasked() {
        XCTAssertFalse(r.redact("SSN 123-45-6789").contains("123-45-6789"))
    }

    func testHighEntropyTokenMasked() {
        // A long random-looking token trips the entropy scan even without a known prefix.
        let token = "Zx9Qm2Vt7Lp4Rs8Wc1Yb6Nk3Fj0Hd5Ga"
        let out = r.redact("value \(token) end")
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("value"))
        XCTAssertTrue(out.contains("end"))
    }

    func testLowEntropyLongWordNotMasked() {
        // Repeated-char long string has low entropy → not masked (avoid nuking prose/ascii art).
        let s = "aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        XCTAssertEqual(r.redact(s), s)
    }

    func testEntropyMeasurement() {
        XCTAssertEqual(SecretRedactor.shannonEntropy(""), 0)
        XCTAssertEqual(SecretRedactor.shannonEntropy("aaaa"), 0, accuracy: 1e-9)
        // "ab" alternating → 1 bit/char.
        XCTAssertEqual(SecretRedactor.shannonEntropy("abab"), 1.0, accuracy: 1e-9)
    }

    func testNonUTF8PassesThrough() {
        let bytes = Data([0xff, 0xfe, 0x00, 0x01])
        XCTAssertEqual(r.redact(bytes), bytes)
    }

    func testDataPathRedactsUTF8() {
        let out = r.redact(Data("AKIAIOSFODNN7EXAMPLE".utf8))
        XCTAssertEqual(String(data: out, encoding: .utf8), "«redacted»")
    }
}
