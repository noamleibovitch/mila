import Foundation

/// The JSON file a post-recording command is handed: everything a script
/// needs to know about one finished recording, in one place, so it never has
/// to read `recordings.json` or guess at file names.
///
/// **This is a contract with code Mila does not ship** — the user's script —
/// so it is a deliberately separate DTO rather than `Recording`'s own Codable,
/// for the same reason `ShareManifest.RecordingPayload` is: a rename inside
/// `Recording` must not silently rename a key somebody's shell script greps
/// for. Additive changes keep `schemaVersion`; removing or re-typing a key
/// bumps it. The schema is documented in `docs/post-recording-command.md`,
/// and `PostRecordingHandoffTests` pins the key set.
struct PostRecordingHandoff: Codable, Equatable {
    static let currentSchemaVersion = 1

    /// Absolute paths of the recording's files. A key is present only when
    /// the file is on disk at the moment the handoff is written.
    struct Files: Codable, Equatable {
        var audio: String?
        var srt: String?
        var txt: String?
        var summary: String?
    }

    struct Item: Codable, Equatable {
        var id: String
        var text: String
        /// As stored on the action item — the label the model or the live
        /// pass attributed it to, if any.
        var speaker: String?
        /// Raw `ActionItem.Source` (`inferred` / `voice_command`).
        var source: String
    }

    var schemaVersion: Int
    var id: String
    var title: String
    /// When the recording was saved. For a recording Mila captured this is
    /// the moment the user pressed Stop (`QuickActionsController.stopRecording`
    /// builds the row with the default `createdAt: Date()`); for an imported
    /// file it is the import time, or the memo's own date for Voice Memos.
    var createdAt: Date
    /// `createdAt - duration`. For a recording Mila captured that is when
    /// it started, except that `duration` leaves out time spent paused, so a
    /// paused recording reads as starting that much later than it did. An
    /// estimate for an import — see `createdAt`.
    var startedAt: Date
    var duration: Double
    var language: String
    /// Raw `RecordingSource` (`microphone` / `systemAudio` / `meeting` /
    /// `voiceMemo`).
    var source: String
    var folder: String?
    var appName: String?
    /// Raw diarizer id → the label the `.srt` and `.txt` sidecars use for it:
    /// the user-assigned name, or the raw id itself for an unnamed speaker.
    /// Empty when diarization did not run.
    var speakers: [String: String]
    var files: Files
    var summary: String?
    var actionItems: [Item]
    /// The calendar event the recording was matched to, when the calendar
    /// match is on and found one. Carries the invite's title and attendees.
    var calendarEvent: CalendarEventMatch?

    /// Build the handoff for `recording`. `audio`/`srt`/`txt`/`summary` are
    /// where the store keeps the files; each is listed only if it exists.
    init(recording: Recording,
         audio: URL,
         srt: URL,
         txt: URL,
         summary summaryURL: URL,
         fileManager: FileManager = .default) {
        func existing(_ url: URL) -> String? {
            fileManager.fileExists(atPath: url.path) ? url.path : nil
        }
        schemaVersion = Self.currentSchemaVersion
        id = recording.id.uuidString
        title = recording.title
        createdAt = recording.createdAt
        startedAt = recording.createdAt.addingTimeInterval(-max(0, recording.duration))
        duration = recording.duration
        language = recording.transcriptLanguage
        source = recording.source.rawValue
        folder = recording.folder
        appName = recording.appName
        var labels: [String: String] = [:]
        for raw in recording.segments.compactMap(\.speaker) where labels[raw] == nil {
            let name = recording.speakerNames[raw]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            labels[raw] = name.isEmpty ? raw : name
        }
        speakers = labels
        files = Files(audio: existing(audio),
                      srt: existing(srt),
                      txt: existing(txt),
                      summary: existing(summaryURL))
        let text = (recording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        summary = text.isEmpty ? nil : text
        actionItems = (recording.actionItems ?? []).map {
            Item(id: $0.id, text: $0.text, speaker: $0.speaker, source: $0.source.rawValue)
        }
        calendarEvent = recording.calendarEvent
    }

    /// The bytes written to `<id>.json`. Sorted keys and ISO-8601 dates so
    /// the file reads the same on every run and `jq` needs no date parsing
    /// tricks; slashes are left alone so paths stay copy-pasteable.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
