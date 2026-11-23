import XCTest
import Combine
@testable import Mila

@MainActor
final class RecordingLocationCoordinatorTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var store: RecordingStore!
    private var storage: RecordingStorageSettings!
    private var readiness: RecordingLibraryReadiness!
    private var coordinator: RecordingLocationCoordinator!
    private var suite: String!
    private var defaults: UserDefaults!

    @MainActor
    private final class Blocker: RecordingLibraryWorkProviding {
        var state: RecordingLibraryWorkState
        init(_ state: RecordingLibraryWorkState) { self.state = state }
        var libraryWorkState: RecordingLibraryWorkState { state }
    }

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "RecordingLocationCoordinatorTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        store = RecordingStore(rootDirectory: root)
        storage = RecordingStorageSettings(defaults: defaults)
        readiness = RecordingLibraryReadiness(providers: [{ self.store.libraryMigrationWorkState }])
        coordinator = RecordingLocationCoordinator(store: store, storage: storage, readiness: readiness)
    }

    override func tearDown() async throws {
        if let suite { defaults.removePersistentDomain(forName: suite) }
        if let base { try? FileManager.default.removeItem(at: base) }
        try await super.tearDown()
    }

    private func makeCustom(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func row(_ title: String = "Meeting", audio: String = "meeting.wav") -> Recording {
        Recording(title: title, duration: 1, source: .microphone,
                  audioFileName: audio, status: .completed)
    }

    private func writeLibrary(_ rows: [Recording], at directory: URL,
                              layout custom: Bool, files: [String: String]) throws {
        let layout = try RecordingLibraryInspection.Layout(directory: directory, defaultRoot: root)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: layout.index)
        for (name, text) in files {
            let base = custom ? directory : layout.directory
            try Data(text.utf8).write(to: base.appendingPathComponent(name))
        }
    }

    func test_successful_index_save_does_not_hide_unsaved_folders() throws {
        // A directory at the file path deterministically refuses atomic writes.
        let foldersURL = root.appendingPathComponent("folders.json")
        try FileManager.default.createDirectory(at: foldersURL, withIntermediateDirectories: false)
        try Data([1]).write(to: foldersURL.appendingPathComponent("sentinel"))
        XCTAssertEqual(store.createFolder("Unsaved folder"), "Unsaved folder")
        XCTAssertTrue(store.hasUnsavedLibraryState)
        store.add(row()) // recordings.json succeeds, folders.json remains unwritten.
        XCTAssertTrue(store.hasUnsavedLibraryState)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertTrue(store.folders.contains("Unsaved folder"))
    }

    func test_successful_folder_save_does_not_hide_unsaved_index() throws {
        let index = root.appendingPathComponent("recordings.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        try Data([1]).write(to: index.appendingPathComponent("sentinel"))
        store.add(row())
        XCTAssertTrue(store.hasUnsavedLibraryState)
        _ = store.createFolder("Saved folder")
        XCTAssertTrue(store.hasUnsavedLibraryState)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertEqual(store.recordings.count, 1)
    }

    func test_prepared_activation_refuses_synchronous_subscriber_mutations() throws {
        let destination = try makeCustom("Reentrant")
        let incoming = row("Incoming")
        try writeLibrary([incoming], at: destination, layout: true, files: [:])
        let index = destination.appendingPathComponent("recordings.json")
        let raw = try Data(contentsOf: index)
        let layout = try RecordingLibraryInspection.Layout(directory: destination, defaultRoot: root)
        let injected = row("Subscriber injection", audio: "injection.wav")
        var refusalObserved = false
        let subscription = store.$recordings.dropFirst().sink { _ in
            self.store.add(injected)
            self.store.rename(incoming, to: "Unexpected rename")
            XCTAssertNil(self.store.createFolder("Unexpected folder"))
            refusalObserved = self.store.libraryMutationWasRefused
        }
        defer { subscription.cancel() }
        try store.activatePrepared(.init(layout: layout, recordings: [incoming], folders: []),
                                   expectedActivity: store.libraryActivity.snapshot,
                                   commitSelection: {})
        XCTAssertTrue(refusalObserved)
        XCTAssertEqual(store.recordings.map(\.id), [incoming.id])
        XCTAssertEqual(store.recordings.first?.title, "Incoming")
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), raw,
                       "Subscribers cannot rewrite the byte-preserved index during activation")
    }

    func test_bookmark_commit_failure_keeps_old_store_selection_and_metadata() async throws {
        let original = row("Original")
        store.add(original)
        let oldDirectory = store.recordingsDirectory
        let destination = try makeCustom("BookmarkFailure")
        let incoming = row("Incoming", audio: "other.wav")
        try writeLibrary([incoming], at: destination, layout: true, files: [:])
        let raw = try Data(contentsOf: destination.appendingPathComponent("recordings.json"))
        coordinator = RecordingLocationCoordinator(store: store, storage: storage, readiness: readiness,
                                                   commitSelection: { _ in false })
        await coordinator.inspectSelection(destination)
        coordinator.select(.useExisting)
        await coordinator.continueSelection()
        guard case .failure(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("still using"))
        XCTAssertEqual(store.recordingsDirectory, oldDirectory)
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("recordings.json")), raw)
    }

    func test_failed_pointer_after_switch_reports_new_folder_and_paused_mcp() async throws {
        let destination = try makeCustom("PointerFailure")
        let incoming = row("New library")
        try writeLibrary([incoming], at: destination, layout: true, files: [:])
        let pointer = root.appendingPathComponent("store-location.json")
        if FileManager.default.fileExists(atPath: pointer.path) { try FileManager.default.removeItem(at: pointer) }
        try FileManager.default.createDirectory(at: pointer, withIntermediateDirectories: false)
        try Data([1]).write(to: pointer.appendingPathComponent("refuse overwrite"))
        coordinator.isMCPEnabled = { true }
        await coordinator.inspectSelection(destination)
        coordinator.select(.useExisting)
        await coordinator.continueSelection()
        guard case .success(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains(destination.path))
        XCTAssertFalse(message.contains("still using the current"))
        XCTAssertFalse(store.storeLocationIsDiscoverable)
        XCTAssertNotNil(coordinator.mcpPauseWarning)
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(storage.customDirectory?.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(store.recordings.map(\.id), [incoming.id])
    }

    func test_space_rechecked_after_preview_before_any_copy_or_switch() async throws {
        let original = row()
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        var free: UInt64 = UInt64.max
        coordinator = RecordingLocationCoordinator(store: store, storage: storage, readiness: readiness,
                                                   capacity: { _ in free })
        let destination = try makeCustom("Space")
        await coordinator.inspectSelection(destination)
        XCTAssertEqual(coordinator.preview?.copyIsAvailable, true)
        coordinator.select(.copy)
        free = 0
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .failure(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("space"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_cancelling_folder_check_settles_before_releasing_source() async throws {
        let destination = try makeCustom("CancelCheck")
        let observer = coordinator.$phase.sink { phase in
            if case .checking = phase { self.coordinator.cancel() }
        }
        defer { observer.cancel() }
        await coordinator.inspectSelection(destination)
        guard case .canceled = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertFalse(store.isChangingRecordingsLocation)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_cancel_before_copy_settles_without_writes_or_false_cleanup_claim() async throws {
        let original = row()
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        let destination = try makeCustom("CancelCopy")
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        let observer = coordinator.$phase.sink { phase in
            if case .copying = phase { self.coordinator.cancel() }
        }
        defer { observer.cancel() }
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .canceled(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertFalse(message.contains("removed the incomplete copy"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertFalse(store.isChangingRecordingsLocation)
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
    }

    func test_copy_bookmark_failure_removes_only_owned_destination_files() async throws {
        let original = row()
        let originals = root.appendingPathComponent("Recordings")
        try writeLibrary([original], at: originals, layout: false,
                         files: ["meeting.wav": "audio", "meeting.txt": "Transcript",
                                 "meeting.srt": "Subtitles", "meeting.summary.txt": "Summary"])
        store.add(original)
        let sourceIndex = try Data(contentsOf: root.appendingPathComponent("recordings.json"))
        let destination = try makeCustom("CopyBookmarkFailure")
        coordinator = RecordingLocationCoordinator(store: store, storage: storage, readiness: readiness,
                                                   commitSelection: { _ in false })
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .failure(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("still using"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recordings.json")), sourceIndex)
        XCTAssertEqual(try Data(contentsOf: originals.appendingPathComponent("meeting.wav")), Data("audio".utf8))
        XCTAssertNil(storage.customDirectory)
    }

    func test_copy_custom_to_custom_preserves_current_library_and_raw_index() async throws {
        let source = try makeCustom("First custom")
        let destination = try makeCustom("Second custom")
        let original = row("Custom recording")
        try writeLibrary([original], at: source, layout: true,
                         files: ["meeting.wav": "audio", "meeting.txt": "Edited transcript",
                                 "meeting.srt": "Subtitles", "meeting.summary.txt": "Summary"])
        try Data("[\"Empty folder\"]".utf8).write(to: source.appendingPathComponent("folders.json"))
        store.relocateRecordings(to: source)
        let index = try Data(contentsOf: source.appendingPathComponent("recordings.json"))
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .success = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
        XCTAssertTrue(store.folders.contains("Empty folder"))
        for name in ["recordings.json", "folders.json", "meeting.wav", "meeting.txt", "meeting.srt", "meeting.summary.txt"] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)),
                           try Data(contentsOf: source.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("recordings.json")), index)
    }

    func test_remove_incomplete_owned_copy_rechecks_before_offering_choices() async throws {
        let original = row()
        let originals = root.appendingPathComponent("Recordings")
        try writeLibrary([original], at: originals, layout: false, files: ["meeting.wav": "audio"])
        store.add(original)
        let destination = try makeCustom("Incomplete")
        let sourceLayout = try RecordingLibraryInspection.Layout(directory: originals, defaultRoot: root)
        let layout = try RecordingLibraryInspection.Layout(directory: destination, defaultRoot: root)
        guard case .existing(let source) = try RecordingLibraryInspection.inspect(sourceLayout) else {
            return XCTFail("Source inspection failed")
        }
        let plan = try RecordingLibraryMigration.makePlan(source: source, destination: layout)
        let stage = try RecordingLibraryMigration.createStage(for: plan)
        try RecordingLibraryMigration.copy(plan, into: stage)
        await coordinator.inspectSelection(destination)
        guard case .incompleteCopy = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        await coordinator.cleanupIncompleteCopy()
        guard case .presenting = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(coordinator.preview?.choices, [.copy, .startFresh])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: originals.appendingPathComponent("meeting.wav")), Data("audio".utf8))
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_repeated_choose_requests_open_only_one_picker() async {
        let opened = expectation(description: "One picker opened")
        let closed = expectation(description: "Picker returned")
        var pickerCount = 0
        var reply: CheckedContinuation<URL?, Never>?
        coordinator.folderPicker = { _ in
            pickerCount += 1
            defer { closed.fulfill() }
            return await withCheckedContinuation { continuation in
                reply = continuation
                opened.fulfill()
            }
        }
        coordinator.chooseFolder()
        coordinator.chooseFolder()
        coordinator.useDefaultLocation()
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(pickerCount, 1)
        reply?.resume(returning: nil)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_cancel_after_incomplete_copy_removed_reports_truthful_canceled_check() async throws {
        let original = row()
        let originals = root.appendingPathComponent("Recordings")
        try writeLibrary([original], at: originals, layout: false, files: ["meeting.wav": "audio"])
        store.add(original)
        let destination = try makeCustom("CancelAfterCleanup")
        let sourceLayout = try RecordingLibraryInspection.Layout(directory: originals, defaultRoot: root)
        let layout = try RecordingLibraryInspection.Layout(directory: destination, defaultRoot: root)
        guard case .existing(let source) = try RecordingLibraryInspection.inspect(sourceLayout) else {
            return XCTFail("Source inspection failed")
        }
        let plan = try RecordingLibraryMigration.makePlan(source: source, destination: layout)
        let stage = try RecordingLibraryMigration.createStage(for: plan)
        try RecordingLibraryMigration.copy(plan, into: stage)
        await coordinator.inspectSelection(destination)
        guard case .incompleteCopy = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        let observer = coordinator.$phase.sink { phase in
            if case .checking = phase { self.coordinator.cancel() }
        }
        defer { observer.cancel() }
        await coordinator.cleanupIncompleteCopy()
        guard case .canceled(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("removed the incomplete copy"))
        XCTAssertFalse(message.contains("couldn’t remove"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertFalse(store.isChangingRecordingsLocation)
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
    }

    func test_startup_recovery_blocks_entry_until_its_whole_lifetime_finishes() async throws {
        let recovery = StartupRecoveryWork()
        readiness.add { recovery.libraryWorkState }
        let destination = try makeCustom("RecoveryEntry")
        recovery.begin()
        await coordinator.inspectSelection(destination)
        guard case .failure = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        recovery.finish()
        coordinator.dismiss()
        await coordinator.inspectSelection(destination)
        guard case .presenting = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
    }

    func test_recovery_admitted_during_copy_refuses_final_activation() async throws {
        let recovery = StartupRecoveryWork()
        readiness.add { recovery.libraryWorkState }
        let original = row()
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        let previous = store.recordingsDirectory
        let destination = try makeCustom("RecoveryDuringCopy")
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        var admitted = false
        let observer = coordinator.progressModel.$progress.sink { value in
            guard let value, value.copiedBytes > 0, !admitted else { return }
            admitted = true
            recovery.begin()
        }
        defer { observer.cancel(); recovery.finish() }
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        XCTAssertTrue(admitted)
        guard case .failure = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordingsDirectory, previous)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func test_work_finished_during_copy_still_invalidates_the_final_revision() async throws {
        let original = row()
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        let originalIndex = try Data(contentsOf: root.appendingPathComponent("recordings.json"))
        let previous = store.recordingsDirectory
        let destination = try makeCustom("TransientWork")
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        var admitted = false
        let observer = coordinator.progressModel.$progress.sink { value in
            guard let value, value.copiedBytes > 0, !admitted else { return }
            admitted = true
            guard let ticket = self.store.beginLibraryWork() else { return XCTFail("Work was unexpectedly refused") }
            self.store.finishLibraryWork(ticket)
        }
        defer { observer.cancel() }
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        XCTAssertTrue(admitted)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recordings.json")), originalIndex)
        guard case .failure = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordingsDirectory, previous,
                       "Matching bytes and no live jobs cannot erase a transient admitted job")
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_postactivation_cleanup_failure_keeps_new_library_and_discloses_retained_stage() async throws {
        let original = row()
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        let destination = try makeCustom("RetainAfterSwitch")
        var planted: URL?
        store.onLibraryActivated = {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
                let stageName = try XCTUnwrap(names.first { $0.hasPrefix(RecordingLibraryMigration.stagePrefix) })
                let file = destination.appendingPathComponent(stageName)
                    .appendingPathComponent(RecordingLibraryMigration.stageFilesName)
                    .appendingPathComponent("unowned.txt")
                try Data("Keep this external file".utf8).write(to: file)
                planted = file
            } catch { XCTFail("Could not inject the cleanup refusal: \(error)") }
        }
        defer { store.onLibraryActivated = nil }
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .success(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains(destination.path))
        XCTAssertTrue(coordinator.lastMessage?.contains("retained a hidden staging copy") == true)
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(planted)), Data("Keep this external file".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("meeting.wav")), Data("audio".utf8))
    }

    func test_same_folder_is_a_no_op_with_no_writes_or_bookmark() async throws {
        let path = store.recordingsDirectory
        await coordinator.inspectSelection(path)
        guard case .noOp(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(message, "Mila is already using this folder.")
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertFalse(coordinator.isSheetPresented)
    }

    func test_copy_then_switch_keeps_originals_and_activates_same_ids() async throws {
        let sourceRow = row()
        try writeLibrary([sourceRow], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio", "meeting.txt": "text"])
        store.add(sourceRow)
        let destination = try makeCustom("Destination")
        await coordinator.inspectSelection(destination)
        XCTAssertEqual(coordinator.preview?.choices, [.copy, .startFresh])
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .success(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains(destination.path))
        XCTAssertEqual(store.recordings.map(\.id), [sourceRow.id])
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("meeting.wav")), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Recordings/meeting.wav")), Data("audio".utf8))
        XCTAssertEqual(storage.customDirectory?.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertNotNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertTrue(store.pendingRecoveryIDs.isEmpty,
                      "Switching must not mint recovery IDs or enqueue transcription")
    }

    func test_start_fresh_refuses_a_destination_index_created_after_preview() async throws {
        store.add(row("Original"))
        let previous = store.recordingsDirectory
        let destination = try makeCustom("ChangedFreshDestination")
        await coordinator.inspectSelection(destination)
        coordinator.select(.startFresh)
        let external = Data("external index sentinel".utf8)
        let index = destination.appendingPathComponent("recordings.json")
        try external.write(to: index)
        await coordinator.continueSelection()
        guard case .failure = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(try Data(contentsOf: index), external)
        XCTAssertEqual(store.recordingsDirectory, previous)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_start_fresh_does_not_copy_and_source_remains() async throws {
        let sourceRow = row()
        try writeLibrary([sourceRow], at: root.appendingPathComponent("Recordings"), layout: false, files: ["meeting.wav": "audio"])
        store.add(sourceRow)
        let destination = try makeCustom("Fresh")
        await coordinator.inspectSelection(destination)
        coordinator.select(.startFresh)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .success = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("recordings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("meeting.wav").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Recordings/meeting.wav")), Data("audio".utf8))
    }

    func test_existing_library_is_adopted_without_merge_and_missing_audio_is_preserved() async throws {
        let destination = try makeCustom("Existing")
        let existing = row("Existing", audio: "lost.wav")
        try writeLibrary([existing], at: destination, layout: true, files: [:])
        await coordinator.inspectSelection(destination)
        XCTAssertEqual(coordinator.preview?.choices, [.useExisting])
        coordinator.select(.useExisting)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .success = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordings.map(\.id), [existing.id])
        XCTAssertEqual(store.recordings.first?.audioFileName, "lost.wav")
        XCTAssertTrue(store.pendingRecoveryIDs.isEmpty)
        XCTAssertTrue(coordinator.lastMessage?.contains("no audio file") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("lost.wav").path))
    }

    func test_busy_owner_refuses_at_entry_without_writing_or_switching() async throws {
        let blocker = Blocker(.busy("Transcription", "still running", generation: 1))
        readiness.add { blocker.libraryWorkState }
        let destination = try makeCustom("Busy")
        await coordinator.inspectSelection(destination)
        guard case .failure(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("Finish"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       root.appendingPathComponent("Recordings").standardizedFileURL)
    }

    func test_source_change_during_copy_refuses_and_leaves_destination_empty() async throws {
        let sourceRow = row()
        try writeLibrary([sourceRow], at: root.appendingPathComponent("Recordings"), layout: false, files: ["meeting.wav": "before"])
        store.add(sourceRow)
        let destination = try makeCustom("Changed")
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        try Data("after".utf8).write(to: root.appendingPathComponent("Recordings/meeting.wav"))
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .failure = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       root.appendingPathComponent("Recordings").standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0 != ".DS_Store" }, [])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Recordings/meeting.wav")),
                       Data("after".utf8))
    }

    func test_missing_audio_source_can_still_copy_and_warn() async throws {
        let missing = row("Gone", audio: "gone.wav")
        try writeLibrary([missing], at: root.appendingPathComponent("Recordings"), layout: false, files: [:])
        store.add(missing)
        let destination = try makeCustom("MissingCopy")
        await coordinator.inspectSelection(destination)
        XCTAssertEqual(coordinator.preview?.sourceMissingAudio, 1)
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        guard case .success = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordings.first?.id, missing.id)
        XCTAssertEqual(store.recordings.first?.audioFileName, "gone.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("gone.wav").path))
        XCTAssertTrue(coordinator.lastMessage?.contains("no audio file") == true)
    }
}

extension RecordingLocationCoordinatorTests {
    func test_copy_cancellation_flag_is_resettable_and_checked_off_main() throws {
        let flag = RecordingLocationCancellation()
        XCTAssertFalse(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
        flag.reset()
        XCTAssertFalse(flag.isCancelled)
        // The migration worker's own cancellation predicate is the same one
        // the copy/publish loops call between chunks and entries.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.wav")
        try Data("source".utf8).write(to: source)
        let manifest = try RecordingLibraryFileCopy.inspect([source])
        let stage = root.appendingPathComponent(".mila-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        flag.cancel()
        XCTAssertThrowsError(try RecordingLibraryFileCopy.copy(manifest, into: stage,
            cancellation: {
                if flag.isCancelled { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
    }
}

extension RecordingLocationCoordinatorTests {
    func test_source_byte_change_then_revert_during_copy_refuses_through_store_activity() async throws {
        var original = row("Transcript", audio: "meeting.wav")
        original.fullText = "Original transcript"
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        let sidecar = root.appendingPathComponent("Recordings/meeting.txt")
        let originalSidecar = try Data(contentsOf: sidecar)
        XCTAssertEqual(originalSidecar, Data("Original transcript".utf8))
        var mutations = 0
        coordinator = RecordingLocationCoordinator(store: store, storage: storage, readiness: readiness,
                                                   beforeFinalVerification: {
            var changed = original
            changed.fullText = "Changed transcript"
            XCTAssertTrue(self.store.update(changed))
            mutations += 1
            XCTAssertEqual(try? Data(contentsOf: sidecar), Data("Changed transcript".utf8))
            XCTAssertTrue(self.store.update(original))
            mutations += 1
        })
        let destination = try makeCustom("ByteRevert")
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        XCTAssertEqual(mutations, 2, "The source bytes changed and were reverted before the final check")
        guard case .failure(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("still using"))
        XCTAssertEqual(try Data(contentsOf: sidecar), originalSidecar)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0 != ".DS_Store" }, [])
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       root.appendingPathComponent("Recordings").standardizedFileURL)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
    }

    func test_failed_transcript_rewrite_and_removal_blocks_migration_entry() async throws {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: " one"),
            TranscriptSegment(start: 1, end: 2, text: " two")
        ]
        var original = row("Trim", audio: "meeting.wav")
        original.segments = segments
        original.fullText = "one two"
        try writeLibrary([original], at: root.appendingPathComponent("Recordings"), layout: false,
                         files: ["meeting.wav": "audio"])
        store.add(original)
        let recordings = root.appendingPathComponent("Recordings")
        let sidecar = recordings.appendingPathComponent("meeting.txt")
        let stale = try Data(contentsOf: sidecar)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordings.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path)
        }

        XCTAssertNotNil(store.deleteSegments([segments[0].id], recordingID: original.id))
        XCTAssertEqual(try Data(contentsOf: sidecar), stale,
                       "The stale sidecar survived both the failed rewrite and the failed removal")
        XCTAssertTrue(store.trimNotice?.contains("couldn't update the transcript's text file") == true)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertEqual(store.libraryMigrationWorkState.reason, "Library changes are not saved yet.")

        let destination = try makeCustom("BusyUnsavedTranscript")
        await coordinator.inspectSelection(destination)
        guard case .failure(let message) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(message.contains("Finish"))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       root.appendingPathComponent("Recordings").standardizedFileURL)
    }
}
