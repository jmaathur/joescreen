import SwiftUI
import JoeScreenKit

/// The shared meeting-notes transcript selected from the sidebar. It is a pure projection of
/// `AppModel.transcript` and
/// `AppModel.transcriptionService` — all merging/boundary logic lives in `TranscriptModel`.
struct TranscriptPane: View {
    @Environment(AppModel.self) private var model

    /// One continuous meeting-notes stream: previous finalized transcription plus live partials.
    /// The merge lives on AppModel so the toolbar's clipboard export shares the same ordering.
    private var meetingNoteSegments: [TranscriptSegment] {
        model.meetingNoteSegmentsSorted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Soft-failure notice: local user isn't contributing segments (others' still render).
            if case .unavailable(let reason) = model.transcriptionService.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }

            // Meeting notes: speaker label + transcription, with live partials dimmed.
            if meetingNoteSegments.isEmpty {
                ContentUnavailableView {
                    Label("No meeting notes yet", systemImage: "text.bubble")
                } description: {
                    Text("Select Transcribe to add the conversation here — every speaker's words, tagged with their name.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Notes read top-down like a document (no bottom anchor — that would also
                // bottom-align short content), while new lines still scroll into view as they land.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(meetingNoteSegments, id: \.segmentID) { seg in
                                TranscriptSegmentRow(seg: seg)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: meetingNoteSegments.last?.segmentID) { _, segmentID in
                        guard let segmentID else { return }
                        withAnimation { proxy.scrollTo(segmentID, anchor: .bottom) }
                    }
                }
            }
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
