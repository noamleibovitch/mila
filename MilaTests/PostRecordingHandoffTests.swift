import XCTest
import TranscriptionCore
@testable import Mila

/// The handoff JSON is a contract with scripts Mila does not ship, so its key
/// set is pinned here: a rename in `Recording` must not rename a key somebody
/// greps for. Adding a key means adding it to these sets (and to
/// `docs/post-recording-command.md`); removing or re-typing one also means
/// bumping `PostRecordingHandoff.currentSchemaVersion`.
final class PostRecordingHandoffTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = TestSupport.makeTempRoot(label: "MilaHandoff")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    private func url(_ name: String, exists: Bool) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        if exists { try Data("x".utf8).write(to: url) }
        return url
    }

    private func fullRecording() -> Recording {
        Recording(
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 90,
            source: .meeting,
            audioFileName: "Weekly sync.m4a",
            status: .completed,
            language: "en",
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "Hi", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 2, end: 4, text: "Hello", speaker: "SPEAKER_01"),
                TranscriptSegment(start: 4, end: 6, text: "Right", speaker: "SPEAKER_00")
            ],
            fullText: "Hi Hello Right",
            folder: "Work",
            appName: "zoom.us",
            summary: "  We agreed on the plan.\n",
            actionItems: [
                ActionItem(id: "a1", text: "Send the deck", speaker: "Dana",
                           timestampSeconds: 3, source: .llmInferred, addedAt: Date()),
                ActionItem(id: "a2", text: "Book a room", speaker: nil,
                           timestampSeconds: 5, source: .voiceCommand, addedAt: Date())
            ],
            speakerNames: ["SPEAKER_00": "Dana"])
    }

    private func makeHandoff(_ recording: Recording, allFilesExist: Bool = true) throws -> PostRecordingHandoff {
        PostRecordingHandoff(recording: recording,
                             audio: try url("a.m4a", exists: allFilesExist),
                             srt: try url("a.srt", exists: allFilesExist),
                             txt: try url("a.txt", exists: allFilesExist),
                             summary: try url("a.summary.txt", exists: allFilesExist))
    }

    private func json(_ handoff: PostRecordingHandoff) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: handoff.encoded()) as? [String: Any])
    }

    func test_schema_key_set_is_pinned() throws {
        let object = try json(makeHandoff(fullRecording()))
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "id", "title", "createdAt", "startedAt", "duration",
            "language", "source", "folder", "appName", "speakers", "files",
            "summary", "actionItems"
        ])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)

        let files = try XCTUnwrap(object["files"] as? [String: Any])
        XCTAssertEqual(Set(files.keys), ["audio", "srt", "txt", "summary"])

        let items = try XCTUnwrap(object["actionItems"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(items.first).keys), ["id", "text", "speaker", "source"])
        XCTAssertEqual(Set(items[1].keys), ["id", "text", "source"],
                       "an action item with no speaker omits the key")
    }

    func test_values_describe_the_recording() throws {
        let recording = fullRecording()
        let handoff = try makeHandoff(recording)
        let object = try json(handoff)

        XCTAssertEqual(object["id"] as? String, recording.id.uuidString)
        XCTAssertEqual(object["title"] as? String, "Weekly sync")
        XCTAssertEqual(object["duration"] as? Double, 90)
        XCTAssertEqual(object["language"] as? String, "en")
        XCTAssertEqual(object["source"] as? String, "meeting")
        XCTAssertEqual(object["folder"] as? String, "Work")
        XCTAssertEqual(object["appName"] as? String, "zoom.us")
        XCTAssertEqual(object["summary"] as? String, "We agreed on the plan.")
        // Dates are ISO-8601 strings, and startedAt is createdAt - duration.
        XCTAssertEqual(object["createdAt"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(object["startedAt"] as? String, "2027-01-15T07:58:30Z")
        // Raw id -> the label the sidecars use: the name, or the raw id.
        XCTAssertEqual(object["speakers"] as? [String: String],
                       ["SPEAKER_00": "Dana", "SPEAKER_01": "SPEAKER_01"])

        XCTAssertEqual(handoff.actionItems.map(\.source), ["inferred", "voice_command"])
        XCTAssertEqual(handoff.files.srt, tempRoot.appendingPathComponent("a.srt").path)
        XCTAssertTrue(try XCTUnwrap(handoff.files.audio).hasPrefix("/"), "paths are absolute")
    }

    func test_absent_files_and_empty_fields_are_omitted() throws {
        let bare = Recording(title: "Memo", duration: 5, source: .microphone,
                             audioFileName: "Memo.wav", fullText: "hello")
        let object = try json(makeHandoff(bare, allFilesExist: false))

        XCTAssertEqual(object["files"] as? [String: String], [:],
                       "a file that is not on disk is not listed")
        XCTAssertNil(object["summary"])
        XCTAssertNil(object["folder"])
        XCTAssertNil(object["appName"])
        XCTAssertEqual(object["speakers"] as? [String: String], [:])
        XCTAssertEqual((object["actionItems"] as? [Any])?.count, 0)
    }

    func test_round_trips_through_codable() throws {
        let handoff = try makeHandoff(fullRecording())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PostRecordingHandoff.self, from: handoff.encoded()), handoff)
    }
}
