import Foundation

/// Never-share blocklist for sensitive apps (spec F-isolation / backlog #4). Password managers,
/// Keychain, and auth surfaces must NEVER be captured — even by accident — so their windows are
/// excluded from the picker, refused on an explicit `shareWindow`, and blocked at capture start.
/// Pure logic (bundle-ID matching, exact + prefix) so the blocklist is unit-tested and one source
/// of truth drives all three enforcement points.
public struct SensitiveAppPolicy: Sendable {

    /// Exact bundle IDs that are always sensitive.
    public let exactBundleIDs: Set<String>
    /// Bundle-ID prefixes; any app whose ID starts with one is sensitive (covers helper/agent
    /// processes like `com.1password.1password-launcher`).
    public let prefixes: [String]

    /// The default blocklist: the common password managers + macOS Keychain/auth surfaces.
    public static let `default` = SensitiveAppPolicy(
        exactBundleIDs: [
            "com.apple.keychainaccess",
            "com.apple.systempreferences",             // may show credentials in some panes
        ],
        prefixes: [
            "com.1password",       // 1Password 7/8 + helpers (com.1password.1password, .1password7, …)
            "com.agilebits",       // legacy 1Password bundle namespace
            "com.bitwarden",       // Bitwarden desktop + helpers
            "com.dashlane",
            "com.lastpass",
            "com.keepassium",
            "org.keepassxc",
            "in.sinew.Enpass",     // Enpass
        ])

    public init(exactBundleIDs: Set<String>, prefixes: [String]) {
        self.exactBundleIDs = exactBundleIDs
        self.prefixes = prefixes
    }

    /// Whether an app (by bundle ID) is sensitive and must never be shared. A nil/empty bundle ID is
    /// treated as NOT sensitive (we can't identify it; the picker still excludes what it can).
    public func isSensitive(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if exactBundleIDs.contains(bundleID) { return true }
        // Case-insensitive prefix match (bundle IDs are conventionally lowercase but be defensive).
        let lower = bundleID.lowercased()
        return prefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    /// The exact + prefix set as a flat list of bundle IDs to hand a picker's `excludedBundleIDs`
    /// (the picker can only exclude what it's given; exact IDs + known prefix roots cover the common
    /// case, and the capture-start check is the belt-and-braces backstop for anything missed).
    public var pickerExcludedBundleIDs: [String] {
        Array(exactBundleIDs) + prefixes
    }
}
