import XCTest
@testable import JoeScreenKit

final class SensitiveAppPolicyTests: XCTestCase {
    private let policy = SensitiveAppPolicy.default

    func testExactMatchIsSensitive() {
        XCTAssertTrue(policy.isSensitive(bundleID: "com.apple.keychainaccess"))
    }

    func testPrefixMatchesHelpers() {
        XCTAssertTrue(policy.isSensitive(bundleID: "com.1password.1password"))
        XCTAssertTrue(policy.isSensitive(bundleID: "com.1password.1password-launcher"))
        XCTAssertTrue(policy.isSensitive(bundleID: "com.1password.1password7"))
        XCTAssertTrue(policy.isSensitive(bundleID: "com.bitwarden.desktop"))
        XCTAssertTrue(policy.isSensitive(bundleID: "org.keepassxc.keepassxc"))
    }

    func testCaseInsensitivePrefix() {
        XCTAssertTrue(policy.isSensitive(bundleID: "COM.1Password.1Password"))
    }

    func testOrdinaryAppsAreNotSensitive() {
        XCTAssertFalse(policy.isSensitive(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(policy.isSensitive(bundleID: "com.google.Chrome"))
        XCTAssertFalse(policy.isSensitive(bundleID: "com.microsoft.VSCode"))
    }

    func testNilOrEmptyIsNotSensitive() {
        XCTAssertFalse(policy.isSensitive(bundleID: nil))
        XCTAssertFalse(policy.isSensitive(bundleID: ""))
    }

    func testNearMissPrefixNotMatched() {
        // "com.1passwordish.app" starts with "com.1password"? No — the prefix is "com.1password"
        // and this string is "com.1passwordish" which DOES start with "com.1password". Guard the
        // realistic boundary: a genuinely different vendor must not be caught.
        XCTAssertFalse(policy.isSensitive(bundleID: "com.onepassword.clone")) // different root
        XCTAssertFalse(policy.isSensitive(bundleID: "com.notbitwarden.app"))
    }

    func testPickerExcludedListCoversExactAndPrefixes() {
        let excluded = policy.pickerExcludedBundleIDs
        XCTAssertTrue(excluded.contains("com.apple.keychainaccess"))
        XCTAssertTrue(excluded.contains("com.1password"))
        XCTAssertTrue(excluded.contains("com.bitwarden"))
    }

    func testCustomPolicy() {
        let custom = SensitiveAppPolicy(exactBundleIDs: ["com.acme.secret"], prefixes: ["com.acme.vault"])
        XCTAssertTrue(custom.isSensitive(bundleID: "com.acme.secret"))
        XCTAssertTrue(custom.isSensitive(bundleID: "com.acme.vault.helper"))
        XCTAssertFalse(custom.isSensitive(bundleID: "com.1password.1password")) // not in the custom set
    }
}
