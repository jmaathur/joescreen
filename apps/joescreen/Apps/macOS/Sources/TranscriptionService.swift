import Foundation
import Observation
import Speech
import AVFoundation

/// Transcribes the LOCAL user's mic with Apple's Speech framework and emits segments for the shared
/// transcript (each participant transcribes their own audio; segments merge on every client).
///
/// Audio comes from a DEDICATED `AVAudioEngine` input tap — separate from LiveKit's mic capture —
/// and voice processing stays OFF on this engine (LiveKit owns AEC on its own). On-device
/// recognition is used when `supportsOnDeviceRecognition`, with the server-based fallback
/// otherwise. Fails SOFT: if speech authorization is denied or the recognizer is unavailable, the
/// local user simply doesn't contribute segments (everyone else's still render) and `state`
/// surfaces why.
///
/// Emission policy: partials are throttled (~300 ms, latest-wins); finals are emitted immediately.
/// Partial updates and the final for one utterance share a `segmentID` so receivers dedupe
/// (final overwrites partial) via `TranscriptModel`.
@MainActor
@Observable
public final class TranscriptionService {

    /// Failures in engine/tap setup that must fail SOFT (state → .unavailable), never crash.
    enum PipelineError: Error {
        case invalidInputFormat
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

    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Identity + start of the utterance currently being recognized (shared by its partials/final).
    private var currentSegmentID = UUID()
    private var currentSegmentStart: TimeInterval = 0
    /// Latest un-emitted partial text (flushed by the throttle loop).
    private var pendingPartial: String?
    private var partialFlushTask: Task<Void, Never>?
    /// Restart guard: recognition tasks error out on a whim (server tasks die ~1/minute); we
    /// restart the pipeline, but not faster than this, to avoid a hot failure loop.
    private var lastRestartAt: TimeInterval = 0

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
        // Speech authorization (NSSpeechRecognitionUsageDescription must be in the plist).
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            AppLog.error("transcription: speech authorization status=\(speechStatus.rawValue)")
            state = .unavailable("Speech recognition not authorized")
            return
        }
        // Mic access for the tap (usually already granted for LiveKit voice).
        guard await Self.ensureMicAccess() else {
            AppLog.error("transcription: mic access denied")
            state = .unavailable("Microphone access denied")
            return
        }
        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            AppLog.error("transcription: recognizer unavailable")
            state = .unavailable("Speech recognizer unavailable")
            return
        }
        self.recognizer = recognizer
        do {
            try startPipeline()
            state = .running
            AppLog.info("transcription started (onDevice=\(recognizer.supportsOnDeviceRecognition))")
        } catch {
            AppLog.error("transcription start failed: \(String(describing: error))")
            state = .unavailable("Transcription failed to start")
        }
    }

    /// Build and start the engine + request + recognition task. The engine is intentionally plain:
    /// no voice processing (AEC/AGC belong to LiveKit's own capture pipeline).
    private func startPipeline() throws {
        guard let recognizer else { return }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // An invalid input format (0 Hz / 0 channels — no usable input device, or the device is
        // exclusively held) makes installTap throw an unrecoverable NSException, not a Swift error.
        // Guard it into the designed soft-failure instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PipelineError.invalidInputFormat
        }
        // The tap block fires on a realtime audio thread, never the main actor — @Sendable so it
        // can't inherit this class's @MainActor isolation (same SIGTRAP class as the recognition
        // callbacks). `request.append` is thread-safe and the request outlives the tap (removed in
        // teardown), so the nonisolated(unsafe) shared reference is sound.
        nonisolated(unsafe) let tappedRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tappedRequest.append(buffer)
        }

        engine.prepare()
        try engine.start()

        // The handler fires on Speech's own queue, NEVER the main actor — it MUST be @Sendable so
        // it doesn't inherit this class's @MainActor isolation (an inherited-isolation closure
        // called off-main trips the Swift 6 runtime executor check → SIGTRAP; this crashed the app
        // in the wild via the sibling authorization callback). Extract the Sendable bits, then hop.
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error.map { String(describing: $0) }
            Task { @MainActor [weak self] in
                self?.handleRecognition(text: text, isFinal: isFinal, errorDescription: errorDescription)
            }
        }

        self.engine = engine
        self.request = request
        mintNewSegment(startedAt: Date().timeIntervalSince1970)
        startPartialFlushLoop()
    }

    private func teardownPipeline() {
        partialFlushTask?.cancel()
        partialFlushTask = nil
        pendingPartial = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: - Recognition results

    private func handleRecognition(text: String?, isFinal: Bool, errorDescription: String?) {
        if let errorDescription {
            AppLog.error("transcription task error: \(errorDescription)")
            // Tasks are not immortal (server-based ones are killed after ~a minute): restart the
            // pipeline while we're supposed to be running — rate-limited against hot loops.
            if state == .running { restartPipeline() }
            return
        }
        guard state == .running, let text, !text.isEmpty else { return }
        if isFinal {
            pendingPartial = nil
            emit(segmentID: currentSegmentID, text: text, startTime: currentSegmentStart, isFinal: true)
            mintNewSegment(startedAt: Date().timeIntervalSince1970)
        } else {
            pendingPartial = text
        }
    }

    private func restartPipeline() {
        let now = Date().timeIntervalSince1970
        guard now - lastRestartAt > 2 else {
            AppLog.error("transcription: restarting too fast — giving up")
            state = .unavailable("Transcription repeatedly failed")
            teardownPipeline()
            return
        }
        lastRestartAt = now
        teardownPipeline()
        do {
            try startPipeline()
            AppLog.info("transcription restarted after task error")
        } catch {
            AppLog.error("transcription restart failed: \(String(describing: error))")
            state = .unavailable("Transcription stopped")
        }
    }

    // MARK: - Emission

    private func mintNewSegment(startedAt: TimeInterval) {
        currentSegmentID = UUID()
        currentSegmentStart = startedAt
    }

    /// ~300 ms latest-wins partial flush: only the newest partial text is emitted per window.
    private func startPartialFlushLoop() {
        partialFlushTask?.cancel()
        partialFlushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                if let text = self.pendingPartial {
                    self.pendingPartial = nil
                    self.emit(segmentID: self.currentSegmentID, text: text,
                              startTime: self.currentSegmentStart, isFinal: false)
                }
            }
        }
    }

    private func emit(segmentID: UUID, text: String, startTime: TimeInterval, isFinal: Bool) {
        onSegment?(segmentID, text, startTime, isFinal)
    }

    // MARK: - Authorization helpers

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
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

    private static func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
