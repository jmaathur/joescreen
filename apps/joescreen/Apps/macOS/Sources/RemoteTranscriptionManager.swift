import Foundation
import AVFoundation
import LiveKit
import JoeScreenKit
import JoeScreenLiveKit

/// Transcribes REMOTE participants' audio locally, one `SpeechRecognitionStream` per speaker, so a
/// single user enabling Transcribe captions the whole room on their own Mac (D19 "multiplayer
/// dictation"). Attribution is structural: each stream is fed by an `AudioRenderer` attached to
/// exactly one participant's decoded audio track (pre-mix), so segments can never be mis-tagged.
///
/// Segments emitted here are LOCAL-ONLY — never broadcast. Every listener could run the same
/// recognition, so broadcasting would multiply each utterance by the listener count; and a speaker
/// who runs their OWN transcription publishes better segments (their mic, their consent), which the
/// app prefers via the self-published suppression window (`AppModel.isSelfPublishingTranscript`).
///
/// Lifecycle: a 2 s poll reconciles per-speaker streams against the transport's current audio
/// tracks — join/leave, publish/unpublish, republish (track identity change), and suppression all
/// converge on the next tick; a stream that dies (recognition failure) is dropped and re-created
/// the same way. Muted publications deliver no buffers, so idle streams cost ~nothing.
@MainActor
final class RemoteTranscriptionManager {

    /// Receives (speakerID, segmentID, text, startTime unix, isFinal) per emitted update.
    var onSegment: (@MainActor (_ speaker: ParticipantID, _ segmentID: UUID, _ text: String,
                                _ startTime: TimeInterval, _ isFinal: Bool) -> Void)?
    /// Speakers currently publishing their OWN transcript segments — their local recognition is
    /// skipped (stream torn down) so their self-published, consented captions win.
    var isSuppressed: (@MainActor (_ speaker: ParticipantID) -> Bool)?

    private struct Entry {
        let track: RemoteAudioTrack
        let renderer: SpeechBufferRenderer
        let stream: SpeechRecognitionStream
    }

    private var entries: [ParticipantID: Entry] = [:]
    private var pollTask: Task<Void, Never>?
    private weak var transport: LiveKitTransport?

    var isRunning: Bool { pollTask != nil }

    func start(transport: LiveKitTransport) {
        guard pollTask == nil else { return }
        self.transport = transport
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (speaker, _) in entries { detach(speaker) }
        entries = [:]
        transport = nil
    }

    /// One reconcile step: streams exist exactly for (current remote audio tracks) minus
    /// (suppressed speakers); a changed track identity (republish) rebuilds the stream.
    private var loggedEmptyTracks = false
    private func reconcile() async {
        guard let transport else { return }
        let tracks = await transport.remoteAudioTracksByParticipant()
        if tracks.isEmpty, !loggedEmptyTracks {
            loggedEmptyTracks = true
            AppLog.info("remote transcription: no subscribed remote audio tracks yet")
        }

        for speaker in entries.keys where tracks[speaker] == nil || isSuppressed?(speaker) == true {
            detach(speaker)
        }
        for (speaker, track) in tracks {
            if isSuppressed?(speaker) == true { continue }
            if let existing = entries[speaker] {
                if existing.track === track, existing.stream.isRunning { continue }
                detach(speaker) // republished track or dead stream — rebuild below
            }
            attach(speaker, track: track)
        }
    }

    private func attach(_ speaker: ParticipantID, track: RemoteAudioTrack) {
        guard let stream = SpeechRecognitionStream() else {
            AppLog.error("remote transcription: no speech recognizer available for \(speaker)")
            return
        }
        stream.onSegment = { [weak self] segmentID, text, startTime, isFinal in
            guard let self else { return }
            // Belt-and-braces: suppression may have flipped between poll ticks.
            if self.isSuppressed?(speaker) == true { return }
            self.onSegment?(speaker, segmentID, text, startTime, isFinal)
        }
        // A dead stream is just dropped; the next reconcile tick re-creates it (natural rate limit).
        stream.onEnded = { [weak self] _ in self?.detach(speaker) }
        let renderer = SpeechBufferRenderer(stream: stream)
        track.add(audioRenderer: renderer)
        stream.start()
        entries[speaker] = Entry(track: track, renderer: renderer, stream: stream)
        AppLog.info("remote transcription attached for \(speaker)")
    }

    private func detach(_ speaker: ParticipantID) {
        guard let entry = entries.removeValue(forKey: speaker) else { return }
        entry.track.remove(audioRenderer: entry.renderer)
        entry.stream.stop()
        AppLog.info("remote transcription detached for \(speaker)")
    }
}

