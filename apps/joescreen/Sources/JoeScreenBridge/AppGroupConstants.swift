import Foundation

/// Shared App Group identity for the host↔extension bridge (spec D11). Must exactly match the
/// `com.apple.security.application-groups` entitlement in the app + extension entitlements files and
/// the App Group registered in the Apple developer portal (see docs/SHIPPING_TESTFLIGHT.md). Using a
/// mismatched ID silently breaks the bridge, so it is defined in ONE place.
public enum AppGroup {
    /// The registered App Group identifier. Matches the entitlements files (macOS `-team`, iOS) and
    /// the portal registration. Format Apple expects: `group.<reverse-dns>`.
    public static let identifier = "group.com.joescreen.app"

    /// Filename of the shared status record inside the group container.
    public static let statusFileName = "broadcast-status.json"

    /// Filename of the shared encoded-frame ring buffer backing store.
    public static let ringBufferFileName = "encoded-frames.ring"
}
