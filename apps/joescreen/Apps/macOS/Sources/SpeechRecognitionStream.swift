import Foundation
import Speech
import AVFoundation
import LiveKit

/// One Apple-Speech recognition stream over an externally-fed PCM buffer source: the per-speaker
/// unit of the transcript pipeline. The LOCAL path feeds it from an `AVAudioEngine` input tap
/// (`TranscriptionService`); the REMOTE path feeds it from a LiveKit `AudioRenderer` per remote
/// participant (`RemoteTranscriptionManager`). Owns the request/task lifecycle, utterance identity
/// (partials + final share a `segmentID`), the ~300 ms latest-wins partial throttle, and the
/// task-death restart loop (server-based tasks die ~1/minute; restarts are rate-limited and the
/// stream reports `onEnded` instead of hot-looping).
///
/// Buffers arrive on realtime/audio threads; `append` is nonisolated and routes through a
/// lock-guarded box holding the CURRENT request, so a mid-restart swap never races the audio thread.
@MainActor
final class SpeechRecognitionStream {

    /// Receives (segmentID, text, startTime unix, isFinal) per emitted update. Main actor.
    var onSegment: (@MainActor (_ segmentID: UUID, _ text: String,
                                _ startTime: TimeInterval, _ isFinal: Bool) -> Void)?
    /// Fired ONCE when the stream dies for good (restart storm / recognizer failure). The owner
    /// decides recovery: the local service surfaces `.unavailable`; the remote manager just drops
    /// the stream and its poll loop re-creates one on a later tick.
    var onEnded: (@MainActor (_ reason: String) -> Void)?

    private(set) var isRunning = false

    private let recognizer: SFSpeechRecognizer
    private var recognitionTask: SFSpeechRecognitionTask?
    /// The current request, shared with the audio thread (see `RequestBox`).
    private let requestBox = RequestBox()

    /// Identity + start of the utterance currently being recognized (shared by its partials/final).
    private var currentSegmentID = UUID()
    private var currentSegmentStart: TimeInterval = 0
    /// Latest un-emitted partial text (flushed by the throttle loop).
    private var pendingPartial: String?
    private var partialFlushTask: Task<Void, Never>?
    /// Restart guard: don't rebuild the task faster than this after an error (hot-loop protection).
    private var lastRestartAt: TimeInterval = 0

    /// nil when the current locale has no speech recognizer.
    init?() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
    }

    var supportsOnDeviceRecognition: Bool { recognizer.supportsOnDeviceRecognition }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startTask()
        startPartialFlushLoop()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        teardownTask()
        partialFlushTask?.cancel()
        partialFlushTask = nil
        pendingPartial = nil
    }

    /// Feed one PCM buffer. Callable from any thread (realtime tap / LiveKit render thread);
    /// buffers arriving mid-restart or after stop are dropped by the box.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        requestBox.append(buffer)
    }

    // MARK: - Task lifecycle

    private func startTask() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true
        requestBox.set(request)
        mintNewSegment(startedAt: Date().timeIntervalSince1970)

        // The handler fires on Speech's own queue, NEVER the main actor — it MUST be @Sendable so
        // it doesn't inherit @MainActor isolation (an inherited-isolation closure called off-main
        // trips the Swift 6 runtime executor check → SIGTRAP; this crashed the app in the wild via
        // the authorization callback). Extract the Sendable bits, then hop.
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let ns = error.map { $0 as NSError }
            let errorDescription = ns.map { String(describing: $0) }
            let errorCode = ns?.code
            let errorDomain = ns?.domain
            Task { @MainActor [weak self] in
                self?.handleRecognition(text: text, isFinal: isFinal, errorDescription: errorDescription,
                                        errorDomain: errorDomain, errorCode: errorCode)
            }
        }
    }

    private func teardownTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.set(nil) // also endAudio()s the old request
        pendingPartial = nil
    }

    // MARK: - Recognition results

    /// kAFAssistantErrorDomain code 1110 = "No speech detected": the recognizer's normal way of
    /// ENDING a task fed silence. It is not a failure — during any real call there are long quiet
    /// stretches, so this fires all the time and must simply roll a fresh task (slightly delayed so
    /// sustained silence costs ~1 task/s at worst, not a hot loop) and never trip the fail limiter.
    private static let noSpeechDetectedCode = 1110

    private func handleRecognition(text: String?, isFinal: Bool, errorDescription: String?,
                                   errorDomain: String? = nil, errorCode: Int? = nil) {
        if let errorDescription {
            guard isRunning else { return }
            if errorDomain == "kAFAssistantErrorDomain", errorCode == Self.noSpeechDetectedCode {
                scheduleBenignRestart()
            } else {
                AppLog.error("speech stream task error: \(errorDescription)")
                // Tasks are not immortal (server-based ones are killed after ~a minute): rebuild
                // the task while we're supposed to be running — rate-limited against hot loops.
                restartTask()
            }
            return
        }
        guard isRunning, let text, !text.isEmpty else { return }
        if isFinal {
            pendingPartial = nil
            emit(segmentID: currentSegmentID, text: text, startTime: currentSegmentStart, isFinal: true)
            mintNewSegment(startedAt: Date().timeIntervalSince1970)
        } else {
            pendingPartial = text
        }
    }

    /// Roll a fresh task after a benign "no speech" end. Small delay so continuous silence re-arms
    /// gently; buffers arriving during the gap are dropped (they're silence by definition).
    private func scheduleBenignRestart() {
        teardownTask()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.isRunning, self.recognitionTask == nil else { return }
            self.startTask()
        }
    }

    private func restartTask() {
        let now = Date().timeIntervalSince1970
        guard now - lastRestartAt > 2 else {
            AppLog.error("speech stream: restarting too fast — ending")
            stop()
            onEnded?("Speech recognition repeatedly failed")
            return
        }
        lastRestartAt = now
        teardownTask()
        startTask()
        AppLog.info("speech stream restarted after task error")
    }

    // MARK: - Emission

    private func mintNewSegment(startedAt: TimeInterval) {
        currentSegmentID = UUID()
        currentSegmentStart = startedAt
    }

    /// ~300 ms latest-wins partial flush: only the newest partial text is emitted per window.
    /// Doubles as the input-level heartbeat: every ~5 s, log the peak sample level seen since the
    /// last heartbeat — the one-line diagnostic that separates "recognizer ignoring speech" from
    /// "audio path is feeding silence/nothing" (buffers=0 means append was never called at all).
    private func startPartialFlushLoop() {
        partialFlushTask?.cancel()
        partialFlushTask = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                if let text = self.pendingPartial {
                    self.pendingPartial = nil
                    self.emit(segmentID: self.currentSegmentID, text: text,
                              startTime: self.currentSegmentStart, isFinal: false)
                }
                ticks += 1
                if ticks % 17 == 0 {
                    let m = self.requestBox.readAndResetMeter()
                    AppLog.info("speech stream level: peak=\(String(format: "%.4f", m.peak)) buffers=\(m.buffers)")
                }
            }
        }
    }

    private func emit(segmentID: UUID, text: String, startTime: TimeInterval, isFinal: Bool) {
        onSegment?(segmentID, text, startTime, isFinal)
    }
}

/// Forwards LiveKit-rendered PCM buffers (delivered on an audio thread) into a recognition stream.
/// Used for BOTH the local mic track (LiveKit's own AEC'd capture — a second AVAudioEngine on the
/// same device receives only silence while VPIO owns it, verified empirically) and each remote
/// participant's decoded track. `SpeechRecognitionStream.append` is nonisolated and lock-guarded,
/// so no isolation hop is needed on the render path.
final class SpeechBufferRenderer: NSObject, AudioRenderer {
    private let stream: SpeechRecognitionStream

    init(stream: SpeechRecognitionStream) {
        self.stream = stream
        super.init()
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        stream.append(pcmBuffer)
    }
}

/// Lock-guarded holder of the CURRENT recognition request, shared between the main actor (which
/// swaps requests across restarts) and the audio threads feeding buffers. `append` on a swapped-out
/// request would silently feed a dead task — the box guarantees buffers always land in the live one
/// (or are dropped when none is live). `SFSpeechAudioBufferRecognitionRequest.append` is itself
/// thread-safe; the lock only guards the request POINTER swap.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Peak |sample| + buffer count since the last meter read (the level heartbeat's source).
    private var meterPeak: Float = 0
    private var meterBuffers: Int = 0

    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = new
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let data = buffer.floatChannelData, buffer.frameLength > 0 {
            for frame in 0..<Int(buffer.frameLength) {
                let v = abs(data[0][frame])
                if v > peak { peak = v }
            }
        }
        lock.lock()
        if peak > meterPeak { meterPeak = peak }
        meterBuffers += 1
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func readAndResetMeter() -> (peak: Float, buffers: Int) {
        lock.lock()
        defer { meterPeak = 0; meterBuffers = 0; lock.unlock() }
        return (meterPeak, meterBuffers)
    }
}
