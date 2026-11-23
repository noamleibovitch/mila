import XCTest
import Darwin
@testable import Mila

@MainActor
final class RecordingLibraryMigrationTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ApplicationSupport/Recordings"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Custom"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func lstatIdentity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: "RecordingLibraryMigrationTests", code: 1)
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private func row(title: String = "Meeting", audio: String = "meeting.wav",
                     folder: String? = "Work", status: TranscriptionStatus = .completed) -> Recording {
        Recording(title: title, duration: 1, source: .microphone,
                  audioFileName: audio, status: status, folder: folder)
    }

    private func writeIndex(_ rows: [Recording], to url: URL, extraKey: String? = nil) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rows)
        guard let extraKey else { try data.write(to: url); return data }
        var object = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for index in object.indices {
            object[index][extraKey] = ["kept": true]
        }
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try raw.write(to: url)
        return raw
    }

    func test_copy_default_to_custom_preserves_raw_metadata_sidecars_folders_and_originals() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let originalRow = row()
            let raw = try writeIndex([originalRow], to: source.index, extraKey: "futureKey")
            try Data("audio bytes".utf8).write(to: recordings.appendingPathComponent("meeting.wav"))
            try Data("Edited transcript".utf8).write(to: recordings.appendingPathComponent("meeting.txt"))
            try Data("Summary".utf8).write(to: recordings.appendingPathComponent("meeting.summary.txt"))
            try Data("SRT".utf8).write(to: recordings.appendingPathComponent("meeting.srt"))
            try Data("[\"Empty folder\"]".utf8).write(to: source.folders)

            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            try RecordingLibraryMigration.verifyPublished(plan, stage: stage)
            try RecordingLibraryMigration.removeStageOnly(stage)

            guard case .existing(let copied) = try RecordingLibraryInspection.inspect(destination) else {
                return XCTFail("destination")
            }
            XCTAssertEqual(copied.indexBytes, raw)
            XCTAssertEqual(copied.foldersBytes, try Data(contentsOf: source.folders))
            XCTAssertEqual(copied.recordings.first?.id, originalRow.id)
            XCTAssertEqual(copied.folderNames, ["Empty folder", "Work"])
            XCTAssertEqual(try Data(contentsOf: destination.directory.appendingPathComponent("meeting.wav")),
                           Data("audio bytes".utf8))
            XCTAssertEqual(try Data(contentsOf: destination.directory.appendingPathComponent("meeting.txt")),
                           Data("Edited transcript".utf8))
            // Source is untouched.
            XCTAssertEqual(try Data(contentsOf: source.index), raw)
            XCTAssertEqual(try Data(contentsOf: recordings.appendingPathComponent("meeting.wav")),
                           Data("audio bytes".utf8))

            // Reopen the same destination through the ordinary store path.
            // The copied raw index must still be byte-identical: the load is
            // a reader here, not a migration of the copied candidate.
            let reopened = RecordingStore(rootDirectory: app, customRecordingsDirectory: custom)
            XCTAssertEqual(reopened.recordings.map(\.id), [originalRow.id])
            XCTAssertEqual(reopened.recordings.first?.audioFileName, "meeting.wav")
            XCTAssertEqual(try Data(contentsOf: destination.index), raw)
        }
    }

    func test_copy_custom_to_default_maps_metadata_and_audio_without_touching_global_siblings() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(
                directory: app.appendingPathComponent("Recordings"), defaultRoot: app)
            let raw = try writeIndex([row()], to: source.index, extraKey: "futureKey")
            try Data("audio".utf8).write(to: custom.appendingPathComponent("meeting.wav"))
            try Data("transcript".utf8).write(to: custom.appendingPathComponent("meeting.txt"))
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Models"),
                                                    withIntermediateDirectories: true)
            try Data("model sentinel".utf8).write(to: app.appendingPathComponent("Models").appendingPathComponent("m.bin"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            try RecordingLibraryMigration.verifyPublished(plan, stage: stage)
            try RecordingLibraryMigration.removeStageOnly(stage)
            XCTAssertEqual(try Data(contentsOf: destination.index), raw)
            XCTAssertEqual(try Data(contentsOf: destination.directory.appendingPathComponent("meeting.wav")),
                           Data("audio".utf8))
            XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Models").appendingPathComponent("m.bin")),
                           Data("model sentinel".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory
                .appendingPathComponent("m.bin").path))
        }
    }

    func test_missing_audio_metadata_is_preserved_without_fabricating_audio_or_ids() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let missing = row(title: "Historical", audio: "lost.wav", folder: nil)
            let raw = try writeIndex([missing], to: source.index)
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            XCTAssertEqual(snapshot.missingAudioCount, 1)
            XCTAssertEqual(snapshot.recordings.first?.id, missing.id)
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            try RecordingLibraryMigration.removeStageOnly(stage)
            guard case .existing(let copied) = try RecordingLibraryInspection.inspect(destination) else {
                return XCTFail("destination")
            }
            XCTAssertEqual(copied.missingAudioCount, 1)
            XCTAssertEqual(copied.indexBytes, raw)
            XCTAssertEqual(copied.recordings.first?.id, missing.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory
                .appendingPathComponent("lost.wav").path))
        }
    }

    func test_exclusive_publication_never_overwrites_and_cleanup_refuses_external_change() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            try Data("source".utf8).write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            let target = custom.appendingPathComponent("meeting.wav")
            try Data("unrelated".utf8).write(to: target)
            XCTAssertThrowsError(try RecordingLibraryMigration.publish(plan, stage: stage)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .destinationExists)
            }
            XCTAssertEqual(try Data(contentsOf: target), Data("unrelated".utf8))
            // Cleanup proves ownership before removing anything; the modified
            // published file and the stage are left in place.
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            try? FileManager.default.removeItem(at: target)
            try Data("changed by someone else".utf8).write(to: target)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt))
            XCTAssertEqual(try Data(contentsOf: target), Data("changed by someone else".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        }
    }

    func test_default_destination_with_existing_index_is_not_a_copy_target() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(
                directory: app.appendingPathComponent("Recordings"), defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            try Data("audio".utf8).write(to: custom.appendingPathComponent("meeting.wav"))
            _ = try writeIndex([], to: destination.index)
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            XCTAssertThrowsError(try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .destinationNotEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: destination.index), try JSONEncoder().encode([Recording]()))
        }
    }
}

extension RecordingLibraryMigrationTests {
    func test_zero_frame_orphan_is_copied_as_bytes_and_never_turned_into_a_row() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([], to: source.index)
            let header: [UInt8] = Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WAVEfmt ".utf8)
                + [16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0]
                + Array("data".utf8) + [0, 0, 0, 0]
            let orphan = recordings.appendingPathComponent("orphan.wav")
            try Data(header).write(to: orphan)
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            XCTAssertEqual(snapshot.emptyAudioFiles, 1)
            XCTAssertEqual(snapshot.recordings.count, 0)
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            try RecordingLibraryMigration.removeStageOnly(stage)
            XCTAssertEqual(try Data(contentsOf: destination.directory.appendingPathComponent("orphan.wav")), Data(header))
            guard case .existing(let copied) = try RecordingLibraryInspection.inspect(destination) else {
                return XCTFail("destination")
            }
            XCTAssertEqual(copied.recordings.count, 0)
            XCTAssertEqual(copied.emptyAudioFiles, 1)
        }
    }
}

extension RecordingLibraryMigrationTests {
    func test_cleanup_retains_identical_racing_destination_after_failed_publication() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            let audio = Data("audio bytes".utf8)
            try audio.write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            // A racing process creates byte-identical content after the plan.
            let target = custom.appendingPathComponent("meeting.wav")
            try audio.write(to: target)
            let before = try lstatIdentity(target)
            XCTAssertThrowsError(try RecordingLibraryMigration.publish(plan, stage: stage)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .destinationExists)
            }
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt))
            let after = try lstatIdentity(target)
            XCTAssertEqual(before.device, after.device)
            XCTAssertEqual(before.inode, after.inode)
            XCTAssertEqual(try Data(contentsOf: target), audio)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        }
    }

    func test_cleanup_retains_inode_replaced_identical_published_file() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            let audio = Data("audio bytes".utf8)
            try audio.write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            let target = custom.appendingPathComponent("meeting.wav")
            let before = try lstatIdentity(target)
            // Replace the published path with identical bytes at a new inode.
            let replacement = custom.appendingPathComponent("replacement.tmp")
            try audio.write(to: replacement)
            XCTAssertEqual(rename(replacement.path, target.path), 0)
            let after = try lstatIdentity(target)
            XCTAssertNotEqual(before.inode, after.inode)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt))
            let current = try lstatIdentity(target)
            XCTAssertEqual(after.device, current.device)
            XCTAssertEqual(after.inode, current.inode)
            XCTAssertEqual(try Data(contentsOf: target), audio)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        }
    }

    func test_remove_stage_only_leaves_planted_stage_file_untouched() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            let audio = Data("audio bytes".utf8)
            try audio.write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            let files = stage.appendingPathComponent(RecordingLibraryMigration.stageFilesName)
            let planted = files.appendingPathComponent("planted.txt")
            try Data("planted".utf8).write(to: planted)
            XCTAssertThrowsError(try RecordingLibraryMigration.removeStageOnly(stage)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .unsafeReceipt)
            }
            XCTAssertEqual(try Data(contentsOf: planted), Data("planted".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertEqual(try Data(contentsOf: custom.appendingPathComponent("meeting.wav")), audio)
        }
    }

    func test_cleanup_removes_owned_staged_files_without_publication() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let raw = try writeIndex([row()], to: source.index)
            let audio = Data("audio bytes".utf8)
            try audio.write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: custom.appendingPathComponent("meeting.wav").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.index.path))
            XCTAssertEqual(try Data(contentsOf: source.index), raw)
        }
    }

    func test_malformed_receipt_refuses_cleanup_and_stage_removal() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            try Data("audio bytes".utf8).write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            let receiptURL = stage.appendingPathComponent(RecordingLibraryMigration.receiptName)
            try Data("not a receipt".utf8).write(to: receiptURL)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .invalidReceipt)
            }
            let staged = stage.appendingPathComponent(RecordingLibraryMigration.stageFilesName)
                .appendingPathComponent("meeting.wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertThrowsError(try RecordingLibraryMigration.removeStageOnly(stage)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .invalidReceipt)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        }
    }

    func test_receipt_relative_paths_are_not_trusted_for_deletion() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            try Data("audio bytes".utf8).write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            let sentinel = root.appendingPathComponent("sentinel.txt")
            try Data("keep me".utf8).write(to: sentinel)
            let receiptURL = stage.appendingPathComponent(RecordingLibraryMigration.receiptName)
            let data = try Data(contentsOf: receiptURL)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var items = object["items"] as! [[String: Any]]
            for index in items.indices where items[index]["name"] as? String == "meeting.wav" {
                items[index]["relativePath"] = sentinel.path
            }
            object["items"] = items
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: receiptURL)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .invalidReceipt)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep me".utf8))
            XCTAssertThrowsError(try RecordingLibraryMigration.removeStageOnly(stage)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .invalidReceipt)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep me".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        }
    }

    func test_cleanup_refreshes_a_precopy_receipt_without_rebinding_it() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            try Data("audio bytes".utf8).write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            // The coordinator captures this receipt before the copy.
            let stale = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            XCTAssertTrue(stale.items.allSatisfy { $0.created == nil })
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            try RecordingLibraryMigration.cleanup(stage: stage, receipt: stale)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: custom.appendingPathComponent("meeting.wav").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.index.path))
        }
    }

    func test_default_layout_cleanup_removes_owned_paths_and_leaves_global_siblings() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(
                directory: app.appendingPathComponent("Recordings"), defaultRoot: app)
            let raw = try writeIndex([row()], to: source.index)
            try Data("audio".utf8).write(to: custom.appendingPathComponent("meeting.wav"))
            let models = app.appendingPathComponent("Models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try Data("model sentinel".utf8).write(to: models.appendingPathComponent("m.bin"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.index.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory
                .appendingPathComponent("meeting.wav").path))
            XCTAssertEqual(try Data(contentsOf: models.appendingPathComponent("m.bin")),
                           Data("model sentinel".utf8))
            XCTAssertEqual(try Data(contentsOf: source.index), raw)
        }
    }
}

extension RecordingLibraryMigrationTests {
    func test_cleanup_refuses_a_symlinked_published_path() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            let audio = Data("audio bytes".utf8)
            try audio.write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            try RecordingLibraryMigration.publish(plan, stage: stage)
            let target = custom.appendingPathComponent("meeting.wav")
            let sentinel = root.appendingPathComponent("sentinel.wav")
            try audio.write(to: sentinel)
            XCTAssertEqual(unlink(target.path), 0)
            XCTAssertEqual(symlink(sentinel.path, target.path), 0)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt))
            XCTAssertEqual(try Data(contentsOf: sentinel), audio)
            XCTAssertEqual(try Data(contentsOf: target), audio)
            var info = stat()
            XCTAssertEqual(lstat(target.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        }
    }
}

extension RecordingLibraryMigrationTests {
    func test_cleanup_refuses_a_supplied_receipt_with_a_different_binding() throws {
        try fixture { root in
            let app = root.appendingPathComponent("ApplicationSupport")
            let recordings = app.appendingPathComponent("Recordings")
            let custom = root.appendingPathComponent("Custom")
            let source = try RecordingLibraryInspection.Layout(directory: recordings, defaultRoot: app)
            let destination = try RecordingLibraryInspection.Layout(directory: custom, defaultRoot: app)
            _ = try writeIndex([row()], to: source.index)
            try Data("audio bytes".utf8).write(to: recordings.appendingPathComponent("meeting.wav"))
            guard case .existing(let snapshot) = try RecordingLibraryInspection.inspect(source) else {
                return XCTFail("source")
            }
            let plan = try RecordingLibraryMigration.makePlan(source: snapshot, destination: destination)
            let stage = try RecordingLibraryMigration.createStage(for: plan)
            try RecordingLibraryMigration.copy(plan, into: stage)
            let receipt = try XCTUnwrap(try RecordingLibraryMigration.loadReceipt(in: destination)?.1)
            let items = receipt.items.map {
                RecordingLibraryMigration.Receipt.Item(
                    name: $0.name, relativePath: $0.relativePath, size: $0.size,
                    digest: String(repeating: "0", count: 64),
                    created: $0.created, published: $0.published)
            }
            let mismatched = RecordingLibraryMigration.Receipt(
                version: receipt.version, operationID: receipt.operationID,
                createdAt: receipt.createdAt, sourceIdentity: receipt.sourceIdentity,
                destinationIdentity: receipt.destinationIdentity, isIndexLast: receipt.isIndexLast,
                items: items)
            XCTAssertThrowsError(try RecordingLibraryMigration.cleanup(stage: stage, receipt: mismatched)) {
                XCTAssertEqual($0 as? RecordingLibraryMigration.Problem, .invalidReceipt)
            }
            let staged = stage.appendingPathComponent(RecordingLibraryMigration.stageFilesName)
                .appendingPathComponent("meeting.wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        }
    }
}
