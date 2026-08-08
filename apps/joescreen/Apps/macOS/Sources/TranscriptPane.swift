import SwiftUI
import JoeScreenKit

/// The shared live transcript + recording-notes pane (third column of SessionView, toggled by the
/// "Notes" control-bar button). Pure projection of `AppModel.transcript` and
/// `AppModel.transcriptionService` — all merging/boundary logic lives in `TranscriptModel`.
struct TranscriptPane: View {
    @Environment(AppModel.self) private var model

    private var isTranscribing: Bool {
        model.transcriptionEnabled
    }

    /// Current note's finalized segments followed by live partials, in time order.
    private var currentSegments: [TranscriptSegment] {
        guard let current = model.transcript.currentNote else { return [] }
        return model.transcript.segments(for: current.noteID) + model.transcript.liveSegments
    }

    /// Newest notes first.
    private var notesNewestFirst: [RecordingNote] {
        Array(model.transcript.notes.reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: pane title + the transcribe toggle (opt-in local mic transcription).
            HStack(spacing: 8) {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button {
                    model.toggleTranscription()
                } label: {
                    Label(isTranscribing ? "Stop" : "Transcribe",
                          systemImage: isTranscribing ? "waveform.circle.fill" : "waveform.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isTranscribing ? Color.accentColor : Color.secondary)
                .help(isTranscribing
                      ? "Stop transcribing the call"
                      : "Transcribe the call: everyone's speech, tagged per speaker (recognized on this Mac)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            // Soft-failure notice: local user isn't contributing segments (others' still render).
            if case .unavailable(let reason) = model.transcriptionService.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }

            // Live shared transcript: speaker label + text, partials dimmed.
            if currentSegments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No transcript yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Enable Transcribe to caption the whole call —\nevery speaker's words, tagged with their name.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(currentSegments, id: \.segmentID) { seg in
                            TranscriptSegmentRow(seg: seg)
                        }
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom)
            }

            Divider()

            // Recording notes: the finalized notes list + the stop/start control (any participant).
            HStack {
                Text("Recording Notes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.transcript.notes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if notesNewestFirst.isEmpty {
                Text("No notes yet this call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notesNewestFirst) { note in
                            RecordingNoteRow(note: note)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Button {
                model.stopAndStartNewNote()
            } label: {
                Label("Stop & New Note", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("Finalize the current recording note and start a new one (shared with everyone)")
        }
        .background(.bar)
    }
}

/// One transcript line: owner-color dot + short speaker label + text. Partials render dimmed.
private struct TranscriptSegmentRow: View {
    @Environment(AppModel.self) private var model
    let seg: TranscriptSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(model.color(for: seg.speakerID))
                .frame(width: 8, height: 8)
            Text(model.displayLabel(for: seg.speakerID))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(seg.text)
                .font(seg.isFinal ? Font.callout : Font.callout.italic())
                .foregroundStyle(seg.isFinal ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One recording-note row: title, start time, segment count, and a "recording" badge while open.
private struct RecordingNoteRow: View {
    @Environment(AppModel.self) private var model
    let note: RecordingNote

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.transcript.displayTitle(for: note.noteID))
                    .font(.callout)
                    .lineLimit(1)
                Text(Date(timeIntervalSince1970: note.startedAt).formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if note.isOpen {
                Text("recording")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Text("\(note.segments.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
