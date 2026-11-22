import XCTest
@testable import Mila

final class RecordingLibraryFileCopyTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent(".mila-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try body(root, stage)
    }

    func test_raw_metadata_unknown_fields_and_all_sidecars_copy_without_touching_source() throws {
        try fixture { root, stage in
            let contents = ["recordings.json": "[{\"futureKey\":{\"keep\":true}}]",
                            "folders.json": "[\"Empty folder\"]", "meeting.wav": "Synthetic audio",
                            "meeting.txt": "Edited transcript", "meeting.summary.txt": "Summary",
                            "meeting.srt": "1\n00:00:00,000 --> 00:00:01,000\nHello"]
            let urls = try contents.map { name, text -> URL in
                let url = root.appendingPathComponent(name)
                try Data(text.utf8).write(to: url)
                return url
            }
            let manifest = try RecordingLibraryFileCopy.inspect(urls)
            try RecordingLibraryFileCopy.copy(manifest, into: stage)
            for (name, text) in contents {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(text.utf8))
                XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(name)), Data(text.utf8))
            }
        }
    }

    func test_source_changed_after_inspection_refuses_before_copying() throws {
        try fixture { root, stage in
            let source = root.appendingPathComponent("audio.wav")
            try Data("before".utf8).write(to: source)
            let manifest = try RecordingLibraryFileCopy.inspect([source])
            try Data("after".utf8).write(to: source)
            XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(manifest, into: stage))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), Data("after".utf8))
        }
    }

    func test_existing_destination_is_never_overwritten() throws {
        try fixture { root, stage in
            let source = root.appendingPathComponent("audio.wav")
            let target = stage.appendingPathComponent("audio.wav")
            try Data("source".utf8).write(to: source)
            try Data("unrelated destination".utf8).write(to: target)
            let manifest = try RecordingLibraryFileCopy.inspect([source])
            XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(manifest, into: stage))
            XCTAssertEqual(try Data(contentsOf: target), Data("unrelated destination".utf8))
        }
    }

    func test_symlink_and_case_colliding_names_refuse() throws {
        try fixture { root, _ in
            let first = root.appendingPathComponent("Audio.wav")
            try Data("audio".utf8).write(to: first)
            let link = root.appendingPathComponent("link.wav")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            XCTAssertThrowsError(try RecordingLibraryFileCopy.inspect([link]))
            // The same physical file with a different spelling must not become
            // two independently owned entries on a case-insensitive volume.
            XCTAssertThrowsError(try RecordingLibraryFileCopy.inspect([first, first]))
        }
    }

    func test_cancellation_during_copy_preserves_sources_and_keeps_partial_output_hidden() throws {
        try fixture { root, stage in
            let source = root.appendingPathComponent("large.wav")
            let data = Data(repeating: 7, count: 2_097_152)
            try data.write(to: source)
            let manifest = try RecordingLibraryFileCopy.inspect([source])
            var cancel = false
            XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(manifest, into: stage,
                cancellation: { if cancel { throw CancellationError() } },
                progress: { _ in cancel = true })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: source), data)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                           Set(["large.wav", stage.lastPathComponent]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), ["large.wav"])
        }
    }
}
