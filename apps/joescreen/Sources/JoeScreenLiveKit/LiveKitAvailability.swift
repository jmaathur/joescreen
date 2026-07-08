import Foundation
import LiveKit

/// Smoke marker that JoeScreenLiveKit links the LiveKit SDK and imports cleanly (M0). The concrete
/// `LiveKitTransport` actor (M2) replaces this as the module's real surface; this constant just
/// gives the target a compilable symbol before that lands and proves the one-libwebrtc adapter
/// target resolves against the pinned SDK.
public enum LiveKitAvailability {
    /// The LiveKit SDK version this adapter is pinned to (DECISIONS D7). A trivial reference to a
    /// LiveKit type here forces the linker to actually pull the SDK, catching a broken pin at build.
    public static let sdkPinnedVersion = "2.15.1"

    /// A no-op that touches a LiveKit type so the import is load-bearing, not merely present.
    public static func linkCheck() -> Bool {
        // `RoomOptions` is a stable public LiveKit type; constructing it proves the SDK is linked.
        _ = RoomOptions()
        return true
    }
}
