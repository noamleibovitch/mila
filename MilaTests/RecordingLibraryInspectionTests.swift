import XCTest
@testable import Mila

final class RecordingLibraryInspectionTests: XCTestCase {
    func test_small_zero_frame_wav_is_preserved_but_large_or_malformed_loose_wav_refuses() throws {
        try fixture { _, app, custom in
            let layout = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try encode([], into: layout.index)
            // Valid mono PCM16 WAV with zero frames: 44-byte header, no audio.
            let header: [UInt8] = Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WAVEfmt ".utf8)
                + [16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0]
                + Array("data".utf8) + [0, 0, 0, 0]
            let audio = custom.appendingPathComponent("empty.wav")
            try Data(header).write(to: audio)
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(layout) else { return XCTFail() }
            XCTAssertEqual(snapshot.emptyAudioFiles, 1)
            XCTAssertEqual(snapshot.recordings.count, 0)
            XCTAssertEqual(Set(snapshot.files.map(\.name)), Set(["recordings.json", "empty.wav"]))
            XCTAssertEqual(try Data(contentsOf: audio), Data(header))
            for invalid in [Data(repeating: 0, count: 4097), Data("invalid small wav".utf8)] {
                try invalid.write(to: audio)
                XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                    XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .unrelatedFiles)
                }
                XCTAssertEqual(try Data(contentsOf: audio), invalid)
            }
        }
    }

    func test_running_and_traversal_references_refuse_before_file_access() throws {
        try fixture { _, app, custom in
            let layout = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            var row = Recording(title: "Running", source: .microphone, audioFileName: "one.wav", status: .running)
            _ = try encode([row], into: layout.index)
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .unsettledRecordings)
            }
            row.status = .completed; row.audioFileName = "../outside.wav"
            _ = try encode([row], into: layout.index)
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .unsafeName)
            }
        }
    }

    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let app = root.appendingPathComponent("ApplicationSupport")
        let custom = root.appendingPathComponent("Custom")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, app, custom)
    }

    private func encode(_ rows: [Recording], into url: URL) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rows)
        try data.write(to: url)
        return data
    }

    func test_empty_directory_and_existing_zero_row_list_are_distinct_without_writes() throws {
        try fixture { _, app, custom in
            let layout = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            guard case .empty = try RecordingLibraryInspection.inspect(layout) else { return XCTFail("Empty folder") }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: custom.path).isEmpty)
            let original = try encode([], into: layout.index)
            guard case .existing(let existing) = try RecordingLibraryInspection.inspect(layout) else {
                return XCTFail("A valid empty list must not become Start fresh")
            }
            XCTAssertEqual(existing.indexBytes, original)
            XCTAssertEqual(existing.recordings.count, 0)
            XCTAssertEqual(try Data(contentsOf: layout.index), original)
        }
    }

    func test_default_layout_keeps_global_models_out_of_library_manifest() throws {
        try fixture { _, app, _ in
            let audio = app.appendingPathComponent("Recordings")
            let models = app.appendingPathComponent("Models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try Data("model sentinel".utf8).write(to: models.appendingPathComponent("model.bin"))
            let layout = try RecordingLibraryInspection.Layout(directory: audio, defaultRoot: app)
            XCTAssertTrue(layout.isDefault)
            XCTAssertEqual(layout.index, app.appendingPathComponent("recordings.json"))
            _ = try encode([], into: layout.index)
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(layout) else { return XCTFail() }
            XCTAssertEqual(snapshot.files.map(\.name), ["recordings.json"])
            XCTAssertEqual(try Data(contentsOf: models.appendingPathComponent("model.bin")), Data("model sentinel".utf8))
        }
    }

    func test_hydrates_sidecars_and_keeps_empty_folders_without_reserializing_metadata() throws {
        try fixture { _, app, custom in
            let layout = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let row = Recording(title: "Edited title", duration: 1, source: .microphone,
                                audioFileName: "meeting.wav", status: .completed, folder: "Used")
            let raw = try encode([row], into: layout.index)
            try Data("audio sentinel".utf8).write(to: custom.appendingPathComponent("meeting.wav"))
            try Data("Edited transcript".utf8).write(to: custom.appendingPathComponent("meeting.txt"))
            try Data("[\"Empty folder\"]".utf8).write(to: layout.folders)
            let before = try FileManager.default.contentsOfDirectory(atPath: custom.path)
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(layout) else { return XCTFail() }
            XCTAssertEqual(snapshot.recordings.first?.id, row.id)
            XCTAssertEqual(snapshot.recordings.first?.fullText, "Edited transcript")
            XCTAssertEqual(snapshot.folderNames, ["Empty folder", "Used"])
            XCTAssertEqual(snapshot.indexBytes, raw)
            XCTAssertEqual(try Data(contentsOf: layout.index), raw)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: custom.path)), Set(before))
        }
    }

    func test_unsettled_rows_missing_audio_shared_stems_and_loose_files_refuse() throws {
        try fixture { _, app, custom in
            let layout = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            var row = Recording(title: "Pending", duration: 1, source: .microphone,
                                audioFileName: "same.wav", status: .pending)
            _ = try encode([row], into: layout.index)
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .unsettledRecordings)
            }
            row.status = .completed
            _ = try encode([row], into: layout.index)
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .missingAudio)
            }
            try Data("wav".utf8).write(to: custom.appendingPathComponent("same.wav"))
            let second = Recording(title: "Other", duration: 1, source: .microphone,
                                   audioFileName: "same.m4a", status: .completed)
            _ = try encode([row, second], into: layout.index)
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .sharedFiles)
            }
            _ = try encode([row], into: layout.index)
            try Data("unrelated".utf8).write(to: custom.appendingPathComponent("notes.doc"))
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .unrelatedFiles)
            }
        }
    }

    func test_duplicate_ids_unsafe_references_and_nested_layouts_refuse() throws {
        try fixture { _, app, custom in
            let layout = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let row = Recording(title: "One", duration: 1, source: .microphone,
                                audioFileName: "one.wav", status: .completed)
            _ = try encode([row, row], into: layout.index)
            XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) {
                XCTAssertEqual($0 as? RecordingLibraryInspection.Problem, .duplicateIdentity)
            }
            XCTAssertThrowsError(try RecordingLibraryInspection.Layout(directory: app, defaultRoot: app))
            XCTAssertThrowsError(try RecordingLibraryInspection.Layout(directory: app.appendingPathComponent("Models"), defaultRoot: app))
            let nested = try RecordingLibraryInspection.Layout(directory: custom.appendingPathComponent("nested"), defaultRoot: app)
            XCTAssertFalse(layout.isSeparate(from: nested))
            XCTAssertFalse(layout.isSeparate(from: layout))
        }
    }
}
