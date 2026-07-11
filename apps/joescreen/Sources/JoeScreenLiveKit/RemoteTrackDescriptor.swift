import Foundation
import LiveKit
import JoeScreenKit

/// A framework-free-ish classification of a remote track's source. Maps LiveKit's `Track.Source` to
/// a stable enum the app/tests switch on without threading LiveKit's type through routing logic
/// (M10's `TrackClassifier` consumes this). `.screenShareVideo` and `.camera` are the two we route;
/// everything else is `.other` (audio, unknown) and ignored by the video path.
public enum RemoteTrackSourceKind: String, Sendable, Equatable {
    case camera
    case screenShareVideo
    case microphone
    case screenShareAudio
    case unknown

    /// Map a LiveKit `Track.Source` into this framework-free enum.
    public init(_ source: Track.Source) {
        switch source {
        case .camera:            self = .camera
        case .screenShareVideo:  self = .screenShareVideo
        case .microphone:        self = .microphone
        case .screenShareAudio:  self = .screenShareAudio
        default:                 self = .unknown
        }
    }

    /// Project to the pure `TrackSource` the JoeScreenKit `TrackClassifier` consumes (camera vs
    /// screen-share vs other — the classifier only needs those three).
    public var trackSource: TrackSource {
        switch self {
        case .camera:           return .camera
        case .screenShareVideo: return .screenShareVideo
        default:                return .other
        }
    }
}

/// The single subscribe-hook contract (the design panel's superset — spec §"shared contracts").
/// Carries everything a consumer needs to route a newly-subscribed remote track WITHOUT reaching
/// back into LiveKit: the stable **SID** (registry key — two `"camera"`-named tracks no longer
/// collide, latent bug #1), the wire **name** (window/display parse), the framework-free
/// **sourceKind**, and the resolved **ownerID** (from the delegate's participant identity, so owner
/// attribution is right at subscribe time rather than falling back to the windowID — latent bug #5).
public struct RemoteTrackDescriptor: Sendable, Equatable {
    /// Stable per-track identifier; the registry key. Unique even when two tracks share a name.
    public let trackSID: String
    /// The wire track name (`window:<uuid>`, `display:<uuid>`, `"camera"`, …).
    public let trackName: String
    /// Framework-free source classification.
    public let sourceKind: RemoteTrackSourceKind
    /// The owning participant, resolved from the delegate's participant identity; nil if unresolved.
    public let ownerID: ParticipantID?

    public init(trackSID: String, trackName: String, sourceKind: RemoteTrackSourceKind, ownerID: ParticipantID?) {
        self.trackSID = trackSID
        self.trackName = trackName
        self.sourceKind = sourceKind
        self.ownerID = ownerID
    }
}

/// Fired when a remote track goes away — from BOTH `didUnsubscribeTrack` AND `didUnpublishTrack`
/// (verified: after a local unsubscribe a later sharer crash fires only `didUnpublishTrack`; hooking
/// one alone leaks a frozen window). Deduped per subscribe-generation inside the transport so the two
/// sources don't double-fire. Carries the same identity fields as the descriptor so the app can find
/// the right lifecycle entry.
public struct RemoteTrackGone: Sendable, Equatable {
    public let trackSID: String
    public let trackName: String
    public let sourceKind: RemoteTrackSourceKind
    public let ownerID: ParticipantID?

    public init(trackSID: String, trackName: String, sourceKind: RemoteTrackSourceKind, ownerID: ParticipantID?) {
        self.trackSID = trackSID
        self.trackName = trackName
        self.sourceKind = sourceKind
        self.ownerID = ownerID
    }
}

/// A per-track `TrackDelegate` that forwards dimension updates to the transport actor. The SDK holds
/// track delegates WEAKLY (`MulticastDelegate`), so the transport must retain this observer for as
/// long as the track is subscribed (it does, in `SubscribedTrack.dimensionObserver`). The callback
/// hops onto the actor. `@unchecked Sendable`: the only stored state is the immutable SID + closure.
final class TrackDimensionObserver: NSObject, TrackDelegate, @unchecked Sendable {
    private let trackSID: String
    private let onDimensions: @Sendable (String, Dimensions?) -> Void

    init(trackSID: String, onDimensions: @escaping @Sendable (String, Dimensions?) -> Void) {
        self.trackSID = trackSID
        self.onDimensions = onDimensions
        super.init()
    }

    func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
        onDimensions(trackSID, dimensions)
    }
}
