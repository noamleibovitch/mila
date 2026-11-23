import XCTest
import Darwin
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

    func test_file_completion_counts_follow_verified_files_including_empty_files() throws {
        try fixture { root, stage in
            let names = ["empty.txt", "large.wav", "small.srt"]
            let bytes = [Data(), Data(repeating: 7, count: 2_097_152), Data([1])]
            for (name, data) in zip(names, bytes) {
                try data.write(to: root.appendingPathComponent(name))
            }
            let entries = try RecordingLibraryFileCopy.inspect(names.map { root.appendingPathComponent($0) })
            var counts: [Int] = []
            var lastBytes: UInt64 = 0
            try RecordingLibraryFileCopy.copy(entries, into: stage,
                progress: { lastBytes = $0 }, completedFile: { count in
                    counts.append(count)
                    let file = stage.appendingPathComponent(names[count - 1])
                    XCTAssertEqual(try? Data(contentsOf: file), bytes[count - 1])
                })
            XCTAssertEqual(counts, [1, 2, 3])
            XCTAssertEqual(lastBytes, 2_097_153)
        }
    }

    func test_staged_byte_corruption_is_refused_before_publication() throws {
        try fixture { root, stage in
            let source = root.appendingPathComponent("corruption.wav")
            let bytes = Data(repeating: 7, count: 2_097_152)
            try bytes.write(to: source)
            let entries = try RecordingLibraryFileCopy.inspect([source])
            var corrupted = false
            XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(entries, into: stage,
                progress: { _ in
                    guard !corrupted else { return }
                    corrupted = true
                    do {
                        let handle = try FileHandle(forWritingTo: stage.appendingPathComponent("corruption.wav"))
                        defer { try? handle.close() }
                        try handle.write(contentsOf: Data([99]))
                        try handle.synchronize()
                    } catch { XCTFail("Could not inject corruption: \(error)") }
                })) { XCTAssertEqual($0 as? RecordingLibraryFileCopy.Problem, .changed) }
            XCTAssertTrue(corrupted)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                           Set(["corruption.wav", stage.lastPathComponent]),
                           "A failed hidden-stage copy must not publish visible library files")
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

extension RecordingLibraryFileCopyTests {
    func test_created_callback_reports_the_verified_staged_identity() throws {
        try fixture { root, stage in
            let source = root.appendingPathComponent("audio.wav")
            try Data("verified bytes".utf8).write(to: source)
            let entries = try RecordingLibraryFileCopy.inspect([source])
            var reported: (name: String, device: UInt64, inode: UInt64)?
            try RecordingLibraryFileCopy.copy(entries, into: stage, created: { name, device, inode in
                reported = (name, device, inode)
            })
            let staged = stage.appendingPathComponent("audio.wav")
            var info = stat()
            XCTAssertEqual(lstat(staged.path, &info), 0)
            XCTAssertEqual(reported?.name, "audio.wav")
            XCTAssertEqual(reported?.device, UInt64(info.st_dev))
            XCTAssertEqual(reported?.inode, UInt64(info.st_ino))
        }
    }
}

extension RecordingLibraryFileCopyTests {
    func test_midcopy_source_byte_change_with_identical_size_is_refused_as_changed() throws {
        try fixture { root, stage in
            let source = root.appendingPathComponent("mutable.wav")
            let original = Data(repeating: 7, count: 2_097_152)
            let altered = Data(repeating: 9, count: original.count)
            try original.write(to: source)
            let manifest = try RecordingLibraryFileCopy.inspect([source])
            var mutated = false
            XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(manifest, into: stage,
                progress: { _ in
                    guard !mutated else { return }
                    mutated = true
                    do {
                        try altered.write(to: source)
                    } catch { XCTFail("Could not mutate the source mid-copy: \(error)") }
                })) {
                XCTAssertEqual($0 as? RecordingLibraryFileCopy.Problem, .changed)
            }
            XCTAssertTrue(mutated)
            XCTAssertEqual(try Data(contentsOf: source), altered)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                           Set(["mutable.wav", stage.lastPathComponent]),
                           "A failed copy must not publish anything outside its hidden stage")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path),
                           ["mutable.wav"])
        }
    }

    func test_midcopy_write_failure_from_stage_path_denial_keeps_source_and_hidden_partial() throws {
        try fixture { root, stage in
            let first = root.appendingPathComponent("a.wav")
            let second = root.appendingPathComponent("b.wav")
            let firstBytes = Data("first".utf8)
            let secondBytes = Data("second".utf8)
            try firstBytes.write(to: first)
            try secondBytes.write(to: second)
            let manifest = try RecordingLibraryFileCopy.inspect([first, second])
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: stage.path)
            }
            XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(manifest, into: stage,
                completedFile: { count in
                    guard count == 1 else { return }
                    do {
                        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                              ofItemAtPath: stage.path)
                    } catch { XCTFail("Could not deny the stage path: \(error)") }
                })) {
                XCTAssertEqual($0 as? RecordingLibraryFileCopy.Problem, .ioFailure)
            }
            XCTAssertEqual(try Data(contentsOf: first), firstBytes)
            XCTAssertEqual(try Data(contentsOf: second), secondBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), ["a.wav"])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                           Set(["a.wav", "b.wav", stage.lastPathComponent]),
                           "Only the hidden stage may hold a partial copy")
        }
    }
}
