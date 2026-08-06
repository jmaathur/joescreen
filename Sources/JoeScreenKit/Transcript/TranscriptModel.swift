import Foundation

/// One recording note: a bounded run of the shared live transcript. Notes are opened/closed by
/// `RecordingNoteEvent`s broadcast on the `transcript` channel, so every participant sees the same
/// notes list and anyone can cut a new one. `segments` are the FINALIZED `TranscriptSegment`s
/// merged from every speaker, ordered by `startTime` (live partials live on `TranscriptModel`,
/// not here).
public struct RecordingNote: Codable, Sendable, Equatable, Identifiable {
    public var noteID: UUID
    /// Display title. Empty until auto-titled from the first finalized words (or an explicit event
    /// title); `TranscriptModel.displayTitle(for:)` falls back to a timestamp label.
    public var title: String
    /// Wall clock (unix seconds) when the note started.
    public var startedAt: TimeInterval
    /// Wall clock (unix seconds) when the note was stopped; `nil` while open.
    public var endedAt: TimeInterval?
    /// Finalized segments, ordered by `startTime` (stable for equal times).
    public var segments: [TranscriptSegment]

    public var id: UUID { noteID }
    /// True while the note is still recording (no stop event applied yet).
    public var isOpen: Bool { endedAt == nil }

    public init(noteID: UUID, title: String = "", startedAt: TimeInterval,
                endedAt: TimeInterval? = nil, segments: [TranscriptSegment] = []) {
        self.noteID = noteID; self.title = title; self.startedAt = startedAt
        self.endedAt = endedAt; self.segments = segments
    }
}

/// The merged shared transcript: an ordered list of recording notes plus the live (partial)
/// segments still in flight. Pure value type — every client runs the same merge over the same
/// `transcript`-channel messages and converges on the same model:
///
/// - Segments dedupe by `segmentID`; a final overwrites its partials, a partial never overwrites
///   a final. Finalized segments are ordered by `startTime` within their note.
/// - Note events apply idempotently, last-writer-wins by event time (`endedAt ?? startedAt`), so
///   duplicated or reordered start/stop broadcasts converge.
/// - A segment arriving before its note's start event materializes an implicit note, which the
///   later start event then fills in (reliable/ordered delivery makes this rare but legal).
public struct TranscriptModel: Sendable, Equatable {

    /// All notes (open + finalized), ordered by start time.
    public private(set) var notes: [RecordingNote]
    /// In-flight partial segments keyed by segmentID (latest update wins). NOT part of `notes` —
    /// finals are what get recorded into a note.
    public private(set) var livePartials: [UUID: TranscriptSegment]

    /// Segment IDs that have finalized; guards against a late partial resurrecting a final.
    private var finalSegmentIDs: Set<UUID>
    /// noteID → event time of the last applied note event (LWW gate).
    private var lastEventAt: [UUID: TimeInterval]

    public init() {
        notes = []
        livePartials = [:]
        finalSegmentIDs = []
        lastEventAt = [:]
    }

    // MARK: - Mutations

    /// Apply a note boundary event. Idempotent; stale events (older than the last applied event
    /// for the same note) are dropped.
    public mutating func apply(_ event: RecordingNoteEvent) {
        let eventTime = event.endedAt ?? event.startedAt
        if let last = lastEventAt[event.noteID], eventTime < last { return }
        lastEventAt[event.noteID] = eventTime

        switch event.action {
        case .start:
            if let idx = index(of: event.noteID) {
                // Fill in an implicit note (created by an early segment) or re-apply a duplicate
                // start. Never clears `endedAt` — a stop can only be superseded by a NEWER event.
                notes[idx].startedAt = event.startedAt
                if !event.title.isEmpty { notes[idx].title = event.title }
            } else {
                notes.append(RecordingNote(noteID: event.noteID, title: event.title,
                                           startedAt: event.startedAt))
            }
            sortNotes()
        case .stop:
            let endedAt = event.endedAt ?? eventTime
            if let idx = index(of: event.noteID) {
                notes[idx].endedAt = endedAt
                if !event.title.isEmpty { notes[idx].title = event.title }
            } else {
                notes.append(RecordingNote(noteID: event.noteID, title: event.title,
                                           startedAt: event.startedAt, endedAt: endedAt))
            }
            sortNotes()
        }
    }

    /// Merge one segment. Finals upsert into their note (ordered); partials go to `livePartials`
    /// (latest-wins per segmentID) and are dropped once the final for that ID exists.
    public mutating func apply(_ segment: TranscriptSegment) {
        if segment.isFinal {
            finalSegmentIDs.insert(segment.segmentID)
            livePartials[segment.segmentID] = nil
            upsertFinal(segment)
        } else {
            guard !finalSegmentIDs.contains(segment.segmentID) else { return }
            livePartials[segment.segmentID] = segment
        }
    }

    // MARK: - Queries

    /// The note currently being recorded: the open note with the latest start time, if any.
    public var currentNote: RecordingNote? {
        notes.filter(\.isOpen).max { $0.startedAt < $1.startedAt }
    }

    public func note(for noteID: UUID) -> RecordingNote? {
        notes.first { $0.noteID == noteID }
    }

    /// Finalized segments of one note, in order.
    public func segments(for noteID: UUID) -> [TranscriptSegment] {
        note(for: noteID)?.segments ?? []
    }

    /// Live partial segments across all speakers, ordered by start time (UI renders them dimmed).
    public var liveSegments: [TranscriptSegment] {
        livePartials.values.sorted { $0.startTime < $1.startTime }
    }

    /// The title to show for a note: its stored/auto-titled text, or a timestamp fallback.
    public func displayTitle(for noteID: UUID) -> String {
        guard let note = note(for: noteID) else { return "" }
        return note.title.isEmpty ? Self.timestampTitle(startedAt: note.startedAt) : note.title
    }

    // MARK: -

    private func index(of noteID: UUID) -> Int? {
        notes.firstIndex { $0.noteID == noteID }
    }

    private mutating func upsertFinal(_ segment: TranscriptSegment) {
        let idx: Int
        if let existing = index(of: segment.noteID) {
            idx = existing
        } else {
            // The note's start event hasn't arrived (or was never sent): materialize an implicit
            // note so the segment is never lost; a later start event fills in the real fields.
            notes.append(RecordingNote(noteID: segment.noteID, startedAt: segment.startTime))
            sortNotes()
            // Re-locate after the sort — the new note may not be last.
            idx = index(of: segment.noteID) ?? notes.count - 1
        }
        if let dup = notes[idx].segments.firstIndex(where: { $0.segmentID == segment.segmentID }) {
            notes[idx].segments[dup] = segment
        } else {
            let pos = notes[idx].segments.firstIndex { $0.startTime > segment.startTime }
                ?? notes[idx].segments.count
            notes[idx].segments.insert(segment, at: pos)
        }
        // Auto-title an untitled note from its first finalized words.
        if notes[idx].title.isEmpty, let first = notes[idx].segments.first {
            notes[idx].title = Self.autoTitle(from: first.text)
        }
    }

    private mutating func sortNotes() {
        notes.sort { ($0.startedAt, $0.noteID.uuidString) < ($1.startedAt, $1.noteID.uuidString) }
    }

    /// "First words" title: up to 8 words of the segment text.
    static func autoTitle(from text: String) -> String {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return "" }
        let title = words.prefix(8).joined(separator: " ")
        return words.count > 8 ? title + "…" : title
    }

    /// Timestamp fallback title, e.g. "Note 2:32 PM".
    static func timestampTitle(startedAt: TimeInterval) -> String {
        "Note " + Date(timeIntervalSince1970: startedAt).formatted(date: .omitted, time: .shortened)
    }
}
