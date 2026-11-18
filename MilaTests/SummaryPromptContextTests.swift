import XCTest
import TranscriptionCore
@testable import Mila

/// Wire-format tests for the facts and the context file the automatic
/// summary can carry. Pure: no store, no settings, no subprocess.
final class SummaryPromptContextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryPromptContextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func recording(title: String = "Weekly sync",
                           source: RecordingSource = .meeting,
                           createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                           duration: Double = 3_120,
                           segments: [TranscriptSegment] = [],
                           names: [String: String] = [:]) -> Recording {
        Recording(title: title, createdAt: createdAt, duration: duration, source: source,
                  audioFileName: "x.wav", segments: segments, speakerNames: names)
    }

    // MARK: - Variables

    func test_absurd_duration_is_empty_and_does_not_trap() {
        XCTAssertEqual(SummaryPromptContext.durationString(1e300), "")
        XCTAssertEqual(SummaryPromptContext.durationString(.infinity), "")
    }

    func test_resolves_every_variable() {
        let rec = recording(segments: [
            TranscriptSegment(start: 0, end: 1, text: "hi", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 1, end: 2, text: "hello", speaker: "SPEAKER_01")
        ], names: ["SPEAKER_00": "Dana"])
        let out = SummaryPromptContext.resolveVariables(
            in: "{{TITLE}}|{{DATE}}|{{DURATION}}|{{SPEAKERS}}|{{MY_NAME}}",
            recording: rec, myName: "Dana", timeZone: utc)
        // 1_800_000_000 is 2027-01-15 08:00:00 UTC; the recording stopped
        // then; DATE is the stored date, not an estimated start.
        XCTAssertEqual(out, "Weekly sync|2027-01-15 08:00|52 min|Dana, SPEAKER_01|Dana")
    }

    func test_prompt_without_tokens_is_returned_unchanged() {
        let prompt = "Summarize the meeting. Use {braces} freely."
        XCTAssertEqual(SummaryPromptContext.resolveVariables(in: prompt, recording: recording(),
                                                             myName: nil, timeZone: utc),
                       prompt)
    }

    /// An unknown fact must not leave its token in the prompt for the model
    /// to trip over.
    func test_unknown_facts_resolve_to_empty() {
        let rec = recording(duration: 0)
        let out = SummaryPromptContext.resolveVariables(
            in: "[{{DURATION}}][{{SPEAKERS}}][{{MY_NAME}}]", recording: rec, myName: nil, timeZone: utc)
        XCTAssertEqual(out, "[][][]")
    }

    /// Substitution is one pass over the template. A value that itself
    /// looks like a token is user text and must come through literally:
    /// replacing token by token would expand a title of "{{SPEAKERS}}" into
    /// the speaker list, depending on which token happened to go first.
    func test_a_value_that_looks_like_a_token_is_not_expanded() {
        let rec = recording(title: "{{SPEAKERS}} and {{MY_NAME}}", segments: [
            TranscriptSegment(start: 0, end: 1, text: "hi", speaker: "SPEAKER_00")
        ], names: ["SPEAKER_00": "{{TITLE}}"])
        let out = SummaryPromptContext.resolveVariables(
            in: "T={{TITLE}} S={{SPEAKERS}} M={{MY_NAME}}", recording: rec,
            myName: "{{DURATION}}", timeZone: utc)
        XCTAssertEqual(out, "T={{SPEAKERS}} and {{MY_NAME}} S={{TITLE}} M={{DURATION}}")
    }

    /// Tokens that are not ours stay exactly as written: `{{LANGUAGE}}`
    /// belongs to the summarizer, and braces in the user's prose are prose.
    func test_unknown_tokens_and_stray_braces_are_left_alone() {
        let prompt = "{{LANGUAGE}} {{ TITLE }} {{nope}} {{TITLE {{TITLE}} tail {{"
        XCTAssertEqual(SummaryPromptContext.resolveVariables(in: prompt, recording: recording(title: "X"),
                                                             myName: nil, timeZone: utc),
                       "{{LANGUAGE}} {{ TITLE }} {{nope}} {{TITLE X tail {{")
    }

    /// A Voice Memo keeps the memo's own date, which is already its start.
    func test_date_is_not_shifted_for_a_voice_memo() {
        let rec = recording(source: .voiceMemo)
        XCTAssertEqual(SummaryPromptContext.recordingDateString(for: rec, timeZone: utc),
                       "2027-01-15 08:00")
    }

    func test_import_date_is_not_invented_from_audio_duration() {
        let rec = recording(source: .microphone, duration: 3600)
        XCTAssertEqual(SummaryPromptContext.recordingDateString(for: rec, timeZone: utc),
                       "2027-01-15 08:00")
    }

    func test_date_is_rendered_in_the_given_time_zone() {
        let jerusalem = TimeZone(identifier: "Asia/Jerusalem")!
        XCTAssertEqual(SummaryPromptContext.recordingDateString(for: recording(), timeZone: jerusalem),
                       "2027-01-15 10:00")
    }

    func test_duration_rounds_to_minutes_and_never_reports_zero() {
        XCTAssertEqual(SummaryPromptContext.durationString(20), "1 min")
        XCTAssertEqual(SummaryPromptContext.durationString(89), "1 min")
        XCTAssertEqual(SummaryPromptContext.durationString(90), "2 min")
        XCTAssertEqual(SummaryPromptContext.durationString(.nan), "")
        XCTAssertEqual(SummaryPromptContext.durationString(-5), "")
    }

    /// Two clusters renamed to one person are one speaker; a speaker with no
    /// text has no line in the transcript and is not listed.
    func test_speaker_list_dedupes_names_and_skips_silent_speakers() {
        let rec = recording(segments: [
            TranscriptSegment(start: 0, end: 1, text: "one", speaker: "SPEAKER_01"),
            TranscriptSegment(start: 1, end: 2, text: "two", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 2, end: 3, text: "three", speaker: "SPEAKER_02"),
            TranscriptSegment(start: 3, end: 4, text: "  ", speaker: "SPEAKER_03"),
            TranscriptSegment(start: 4, end: 5, text: "no label", speaker: nil)
        ], names: ["SPEAKER_01": "Yossi", "SPEAKER_00": "Dana", "SPEAKER_02": "Yossi"])
        XCTAssertEqual(SummaryPromptContext.speakerList(for: rec), "Yossi, Dana")
    }

    func test_multi_line_title_is_flattened() {
        let rec = recording(title: "Line one\nLine two")
        XCTAssertEqual(SummaryPromptContext.resolveVariables(in: "{{TITLE}}", recording: rec,
                                                             myName: nil, timeZone: utc),
                       "Line one Line two")
    }

    // MARK: - Context file

    private func write(_ text: String, named name: String = "context.md") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func test_blank_path_is_not_set() {
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: "   "), .notSet)
    }

    func test_reads_and_trims_a_file() throws {
        let path = try write("\n  Dana leads Platform.\n\n")
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: path), .ready("Dana leads Platform."))
    }

    func test_missing_file_and_directory_are_missing() {
        XCTAssertEqual(SummaryPromptContext.loadContextFile(
            at: tempDir.appendingPathComponent("nope.md").path), .missing)
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: tempDir.path), .missing)
    }

    func test_zero_byte_regular_file_is_empty() throws {
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: try write("")), .empty)
    }

    func test_whitespace_only_file_is_empty() throws {
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: try write(" \n\t\n")), .empty)
    }

    func test_file_over_the_cap_is_too_large() throws {
        let big = String(repeating: "a", count: SummaryPromptContext.maxContextFileBytes + 1)
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: try write(big)), .tooLarge)
    }

    func test_non_utf8_file_is_unreadable() throws {
        let url = tempDir.appendingPathComponent("latin1.txt")
        try Data([0xFF, 0xFE, 0xFA, 0x80]).write(to: url)
        XCTAssertEqual(SummaryPromptContext.loadContextFile(at: url.path), .unreadable)
    }

    func test_nil_or_blank_context_leaves_the_prompt_byte_identical() {
        XCTAssertEqual(SummaryPromptContext.prompt("P", withContext: nil), "P")
        XCTAssertEqual(SummaryPromptContext.prompt("P", withContext: " \n "), "P")
    }

    func test_context_goes_before_the_prompt_inside_a_labelled_block() {
        let out = SummaryPromptContext.prompt("Summarize.", withContext: "Dana leads Platform.")
        XCTAssertTrue(out.hasSuffix("</context>\n\nSummarize."))
        XCTAssertTrue(out.contains("<context>\nDana leads Platform.\n</context>"))
        XCTAssertTrue(out.hasPrefix("Background from the user"))
    }
}
