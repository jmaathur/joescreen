import Foundation
import Observation
import Speech
import AVFoundation
import LiveKit

/// Transcribes the LOCAL user's mic with Apple's Speech framework and emits segments for the shared
/// transcript. The local user's segments are broadcast to every peer; remote participants' audio is
/// transcribed locally by `RemoteTranscriptionManager` (D19), so one person enabling Transcribe
/// captions the whole room on their own Mac.
///
/// Audio comes from an `AudioRenderer` on LiveKit's OWN published mic track — NOT a second
/// `AVAudioEngine`: while LiveKit's VoiceProcessingIO owns the input device, a second plain engine
/// on the same device receives only silence (verified empirically — the original dedicated-engine
/// design produced `peak=0.0000` forever). The track feed is AEC'd, and a muted publication
/// delivers no buffers, so a muted mic is never transcribed. Recognition itself (request/task
/// lifecycle, utterance identity, partial throttle, benign "no speech" restarts) lives in
/// `SpeechRecognitionStream`. Fails SOFT: if speech authorization is denied or the recognizer is
/// unavailable, the local user simply doesn't contribute segments (remote captions still work) and
/// `state` surfaces why.
@MainActor
@Observable
public final class TranscriptionService {

    /// Failures in pipeline setup that must fail SOFT (state → .unavailable), never crash.
    enum PipelineError: Error {
        case recognizerUnavailable
    }

    public enum State: Equatable {
        case off
        case running
        /// Soft failure with a user-presentable reason (auth denied / recognizer unavailable).
        case unavailable(String)
    }

    public private(set) var state: State = .off

    /// Receives (segmentID, text, startTime unix, isFinal) for each emitted segment update.
    /// Called on the main actor.
    public var onSegment: (@MainActor (_ segmentID: UUID, _ text: String,
                                       _ startTime: TimeInterval, _ isFinal: Bool) -> Void)?

    /// Provider of the CURRENT local mic track (the transport's, injected by AppModel). Nil until
    /// the mic has been enabled once; the attach loop keeps polling, so transcription starts
    /// flowing whenever the track appears (or re-appears with a new identity after a republish).
    public var localAudioTrack: (@MainActor () async -> LocalAudioTrack?)?

    private var stream: SpeechRecognitionStream?
    private var renderer: SpeechBufferRenderer?
    private var attachedTrack: LocalAudioTrack?
    private var attachTask: Task<Void, Never>?

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard state == .off else { return }
        Task { await startAsync() }
    }

    public func stop() {
        guard state != .off else { return }
        state = .off
        teardownPipeline()
        AppLog.info("transcription stopped")
    }

    private func startAsync() async {
        // Speech authorization (NSSpeechRecognitionUsageDescription must be in the plist). Mic
        // capture itself is LiveKit's (already TCC-prompted for voice at join) — no second grant.
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            AppLog.error("transcription: speech authorization status=\(speechStatus.rawValue)")
            state = .unavailable("Speech recognition not authorized")
            return
        }
        do {
            try startPipeline()
            state = .running
        } catch {
            AppLog.error("transcription start failed: \(String(describing: error))")
            state = .unavailable("Transcription failed to start")
        }
    }

    /// Build the recognition stream and start the track-attach loop.
    private func startPipeline() throws {
        guard let stream = SpeechRecognitionStream() else {
            AppLog.error("transcription: recognizer unavailable")
            throw PipelineError.recognizerUnavailable
        }
        stream.onSegment = { [weak self] segmentID, text, startTime, isFinal in
            self?.onSegment?(segmentID, text, startTime, isFinal)
        }
        stream.onEnded = { [weak self] reason in
            guard let self, self.state == .running else { return }
            self.state = .unavailable(reason)
            self.teardownPipeline()
        }
        stream.start()
        self.stream = stream
        self.renderer = SpeechBufferRenderer(stream: stream)
        startAttachLoop()
        AppLog.info("transcription started (onDevice=\(stream.supportsOnDeviceRecognition))")
    }

    /// Keep the renderer attached to the CURRENT local mic track: the track doesn't exist until
    /// the mic is first enabled, and its identity changes on republish, so a 2 s reconcile loop
    /// (same pattern as `RemoteTranscriptionManager`) beats one-shot attachment.
    private func startAttachLoop() {
        attachTask?.cancel()
        attachTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.reconcileTrack()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reconcileTrack() async {
        guard state == .running, let renderer, let provider = localAudioTrack else { return }
        let track = await provider()
        guard track !== attachedTrack else { return }
        attachedTrack?.remove(audioRenderer: renderer)
        attachedTrack = track
        if let track {
            track.add(audioRenderer: renderer)
            AppLog.info("transcription attached to local mic track")
        }
    }

    private func teardownPipeline() {
        attachTask?.cancel()
        attachTask = nil
        if let renderer, let attachedTrack {
            attachedTrack.remove(audioRenderer: renderer)
        }
        attachedTrack = nil
        renderer = nil
        stream?.stop()
        stream = nil
    }

    // MARK: - Authorization helpers

    static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            // TCC invokes this on its own XPC reply queue, never the main actor. Without @Sendable
            // the closure inherits this type's @MainActor isolation and the Swift 6 runtime's
            // executor assertion crashes the app (dispatch_assert_queue_fail → SIGTRAP) the first
            // time a user with fresh TCC state taps Transcribe. Continuations are thread-safe.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                cont.resume(returning: status)
            }
        }
    }
}
