import Foundation

/// The SharePlay activity that starts/joins a JoeScreen session (spec §3.1 / D8).
///
/// This is the *control-plane entry point only*: GroupActivities carries session membership,
/// presence, and signaling — never media (256 KB messenger cap, rate-limited; verified API fact).
/// All real-time video/input rides the LiveKit media plane behind `MediaTransport`.
///
/// Layering: the always-compiling core below is a plain `Codable` value so JoeScreenKit's tests
/// and non-Apple-framework consumers (e.g. the broadcast extension via JoeScreenBridge) never pull
/// in GroupActivities. On real app targets the same type picks up:
///   - `GroupActivity` (guarded below behind `#if canImport(GroupActivities)`), and
///   - `Transferable` via `GroupActivityTransferRepresentation` for the ShareLink start flow
///     (macOS 14 / iOS 17 floor per D2) — added in the app layer, see TODO.
///
/// // TODO(Phase1): app layer adds `Transferable` conformance using
/// // `GroupActivityTransferRepresentation` so `ShareLink(item: activity, ...)` can start the
/// // session without a FaceTime call already running.
public struct JoeScreenActivity: Codable, Sendable, Equatable {

    /// Stable activity identifier registered in both app targets' `NSSupportsGroupActivities`
    /// plumbing. NEVER change after ship: peers on different builds must resolve the SAME
    /// activity or they can't rendezvous.
    public static let activityIdentifier = "com.joescreen.app.session"

    /// Plain Codable session metadata carried inside the activity payload. Kept framework-free so
    /// the same values feed `GroupActivityMetadata` (app targets) and unit tests (SwiftPM gate).
    public struct SessionInfo: Codable, Sendable, Equatable {
        /// Human-readable session name shown in the SharePlay join sheet.
        public var sessionName: String
        /// Display name of the participant who started the session (advisory, UI only).
        public var hostDisplayName: String
        /// Creation timestamp (host clock) — lets late joiners show session age.
        public var createdAt: Date

        public init(sessionName: String, hostDisplayName: String, createdAt: Date = Date()) {
            self.sessionName = sessionName
            self.hostDisplayName = hostDisplayName
            self.createdAt = createdAt
        }
    }

    public var info: SessionInfo

    public init(info: SessionInfo) {
        self.info = info
    }
}

#if canImport(GroupActivities)
import GroupActivities

/// Real-target conformance. `Self.activityIdentifier` (declared on the core struct above)
/// satisfies the protocol's static requirement; the synchronous `metadata` getter satisfies the
/// async requirement.
@available(macOS 14, iOS 17, *)
extension JoeScreenActivity: GroupActivity {
    public var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = info.sessionName
        meta.type = .generic
        return meta
    }
}
#endif
