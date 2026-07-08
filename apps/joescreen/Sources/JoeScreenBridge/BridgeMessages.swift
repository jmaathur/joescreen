import Foundation

/// Control messages passed between the iOS broadcast extension and the host app over the App Group
/// (spec D11 / R19). Deliberately dependency-free (no GroupActivities/LiveKit) so the extension can
/// link this target under its ~50 MB budget.
public enum BroadcastState: String, Codable, Sendable, Equatable {
    case started
    case paused     // device locked / incoming call — the extension may NOT survive (R19)
    case resumed
    case finished
}

/// Describes the encoded video format the extension is producing, so the host can configure its
/// LiveKit track / decoder before frames arrive.
public struct EncodedFormatDescription: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Codec fourcc-ish tag; iOS extension path is always H.264 (D11).
    public var codec: String
    public var frameRate: Int
    public init(width: Int, height: Int, codec: String = "h264", frameRate: Int = 30) {
        self.width = width; self.height = height; self.codec = codec; self.frameRate = frameRate
    }
}

/// A small status record the extension writes and the host reads (last-known state survives a
/// reader restart — used to show "sharing interrupted (device locked)" with one-tap restart).
public struct BridgeStatus: Codable, Sendable, Equatable {
    public var state: BroadcastState
    public var format: EncodedFormatDescription?
    /// Monotonic counter so the host can detect a stale record.
    public var revision: UInt64
    public init(state: BroadcastState, format: EncodedFormatDescription? = nil, revision: UInt64 = 0) {
        self.state = state; self.format = format; self.revision = revision
    }
}
