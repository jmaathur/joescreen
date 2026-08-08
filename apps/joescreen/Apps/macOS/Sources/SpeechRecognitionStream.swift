import Foundation
import Speech
import AVFoundation
import LiveKit

/// One Apple-Speech recognition stream over an externally-fed PCM buffer source: the per-speaker
/// unit of the transcript pipeline. The LOCAL path feeds it from LiveKit's own mic capture
/// (`TranscriptionService`); the REMOTE path feeds it from a LiveKit `AudioRenderer` per remote
/// participant (`RemoteTranscriptionManager`). Owns the request/task lifecycle, utterance identity
/// (partials + final share a `segmentID`), the ~300 ms latest-wins partial throttle, and the
/// task-death restart loop (restarts are rate-limited and the stream reports `onEnded` instead of
/// hot-looping).
///
/// **Utterance segmentation is load-bearing** (verified empirically on macOS 15.6):
/// `SFSpeechAudioBufferRecognitionRequest` delivers NO results — not even partials — until
/// `endAudio()` is called; an endless live stream therefore produces literally nothing (plus
/// periodic 1110 "no speech" task deaths). So this stream runs its own energy VAD on the flush
/// loop: once speech has been heard and then ~1 s of trailing silence, it ends the current
/// request's audio → the recognizer flushes partials + the final in one burst → the final rotates
/// to a fresh request/task for the next utterance. A max-utterance cap forces a flush during long
/// monologues so text keeps appearing.
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

    // MARK: Utterance segmentation (energy VAD driven from the flush loop's 300 ms ticks)

    /// A tick whose peak exceeds this counts as speech. Converted Float32 samples; normal speech
    /// registers well above (0.05+), room tone below.
    private static let speechPeakThreshold: Float = 0.015
    /// Trailing silence that ends an utterance and flushes the recognizer.
    private static let utteranceSilenceSeconds: TimeInterval = 1.0
    /// Force a flush after this much continuous speech so long monologues still produce text.
    private static let maxUtteranceSeconds: TimeInterval = 12
    /// Whether speech has been heard on the CURRENT request (nothing to flush before that).
    private var sawSpeechThisUtterance = false
    /// When speech was last heard / when the current request's task started.
    private var lastSpeechAt: TimeInterval = 0
    private var taskStartedAt: TimeInterval = 0
    /// True once endAudio() was called on the current request (awaiting the flush + final).
    private var audioEnded = false

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
        // Fresh request → fresh utterance state for the VAD.
        sawSpeechThisUtterance = false
        audioEnded = false
        taskStartedAt = Date().timeIntervalSince1970

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
            // The final ends this request's life (its audio was ended to force the flush — see the
            // VAD in the flush loop). Rotate to a fresh request/task for the next utterance.
            teardownTask()
            startTask()
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

    /// The ~300 ms tick loop: flushes throttled partials, runs the utterance VAD (the thing that
    /// actually makes results appear — see the type doc), and logs an input-level heartbeat every
    /// ~5 s (`peak=`/`buffers=` — the diagnostic separating "recognizer ignoring speech" from
    /// "audio path is feeding silence/nothing"; buffers=0 means append was never called at all).
    private func startPartialFlushLoop() {
        partialFlushTask?.cancel()
        partialFlushTask = Task { @MainActor [weak self] in
            var ticks = 0
            var heartbeatPeak: Float = 0
            var heartbeatBuffers = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                if let text = self.pendingPartial {
                    self.pendingPartial = nil
                    self.emit(segmentID: self.currentSegmentID, text: text,
                              startTime: self.currentSegmentStart, isFinal: false)
                }
                let m = self.requestBox.readAndResetMeter()
                self.evaluateUtterance(tickPeak: m.peak)
                heartbeatPeak = max(heartbeatPeak, m.peak)
                heartbeatBuffers += m.buffers
                ticks += 1
                if ticks % 17 == 0 {
                    AppLog.info("speech stream level: peak=\(String(format: "%.4f", heartbeatPeak)) buffers=\(heartbeatBuffers)")
                    heartbeatPeak = 0
                    heartbeatBuffers = 0
                }
            }
        }
    }

    /// One VAD step: track speech energy; after speech + trailing silence (or an over-long
    /// utterance), end the current request's audio so the recognizer flushes its results. The
    /// resulting final rotates the task; a silence-only request just 1110s and rolls over.
    private func evaluateUtterance(tickPeak: Float) {
        guard recognitionTask != nil, !audioEnded else { return }
        let now = Date().timeIntervalSince1970
        if tickPeak > Self.speechPeakThreshold {
            sawSpeechThisUtterance = true
            lastSpeechAt = now
        }
        guard sawSpeechThisUtterance else { return }
        let trailingSilence = now - lastSpeechAt
        let utteranceAge = now - taskStartedAt
        if trailingSilence >= Self.utteranceSilenceSeconds || utteranceAge >= Self.maxUtteranceSeconds {
            audioEnded = true
            requestBox.endAudio()
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
    /// Converter to Float32 mono. LiveKit's WebRTC render path delivers Int16 PCM buffers —
    /// `SFSpeechAudioBufferRecognitionRequest.append` silently produces NOTHING for those (endless
    /// "no speech detected", zero partials, no error anywhere), and Int16 also defeats float-based
    /// metering (`floatChannelData == nil` → a phantom peak=0.0000). Convert EVERYTHING to the
    /// recognizer-native Float32 before appending. Rebuilt when the input format changes.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var loggedFormat = false
    /// Debug tap (JOESCREEN_DUMP_SPEECH_AUDIO=1): writes the exact converted audio the recognizer
    /// receives to a wav in /tmp, so "recognizer got garbage" vs "recognizer ignored good audio"
    /// is decidable by listening to / file-recognizing the dump.
    private var debugFile: AVAudioFile?
    private var debugFileTried = false

    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = new
        lock.unlock()
        old?.endAudio()
    }

    /// End the CURRENT request's audio (the utterance-VAD flush trigger) without swapping it out —
    /// the recognizer then delivers its buffered results + final for this request.
    func endAudio() {
        lock.lock()
        let current = request
        lock.unlock()
        current?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if !loggedFormat {
            loggedFormat = true
            AppLog.info("speech stream input format: \(buffer.format)")
        }
        guard let converted = convertToFloat32Mono(buffer) else { return }
        if !debugFileTried {
            debugFileTried = true
            if ProcessInfo.processInfo.environment["JOESCREEN_DUMP_SPEECH_AUDIO"] == "1" {
                let path = "/tmp/js-speech-\(UInt32.random(in: 1000...9999)).wav"
                debugFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                             settings: converted.format.settings)
                AppLog.info("speech stream: dumping recognizer audio to \(path)")
            }
        }
        try? debugFile?.write(from: converted)
        var peak: Float = 0
        if let data = converted.floatChannelData, converted.frameLength > 0 {
            for frame in 0..<Int(converted.frameLength) {
                let v = abs(data[0][frame])
                if v > peak { peak = v }
            }
        }
        lock.lock()
        if peak > meterPeak { meterPeak = peak }
        meterBuffers += 1
        let current = request
        lock.unlock()
        current?.append(converted)
    }

    /// Convert an arbitrary PCM buffer to deinterleaved Float32 mono at the same sample rate.
    /// Returns the buffer unchanged when it's already in that shape. Called only from the single
    /// audio/render thread that feeds this stream, so converter state needs no extra locking.
    private func convertToFloat32Mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFormat = buffer.format
        if inFormat.commonFormat == .pcmFormatFloat32, inFormat.channelCount == 1, !inFormat.isInterleaved {
            return buffer
        }
        if converter == nil || converterInputFormat != inFormat {
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: inFormat.sampleRate,
                                                channels: 1, interleaved: false),
                  let newConverter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
            converter = newConverter
            converterInputFormat = inFormat
        }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: buffer.frameLength) else { return nil }
        // Same sample rate in/out → one buffer in, one buffer out; the block feeds the input once.
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    func readAndResetMeter() -> (peak: Float, buffers: Int) {
        lock.lock()
        defer { meterPeak = 0; meterBuffers = 0; lock.unlock() }
        return (meterPeak, meterBuffers)
    }
}
