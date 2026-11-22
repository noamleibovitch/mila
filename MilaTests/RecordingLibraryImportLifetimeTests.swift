import XCTest
import Combine
@testable import Mila

@MainActor
final class RecordingLibraryImportLifetimeTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var store: RecordingStore!
    private var heldReencoders: [HeldReencode] = []
    private var importTasks: [Task<Recording, Error>] = []

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingLibraryImportLifetimeTests-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: root)
    }

    override func tearDown() async throws {
        for held in heldReencoders { held.releaseAll() }
        for task in importTasks { _ = try? await task.value }
        importTasks.removeAll()
        heldReencoders.removeAll()
        if let base { try? FileManager.default.removeItem(at: base) }
        try await super.tearDown()
    }

    private func makeSource(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data("synthetic source bytes".utf8).write(to: url)
        return url
    }

    private func makeDestination(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCoordinator(beforeFinalVerification: (@MainActor () async -> Void)? = nil)
        -> (RecordingLocationCoordinator, UserDefaults, String) {
        let suite = "RecordingLibraryImportLifetimeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = RecordingStorageSettings(defaults: defaults)
        let readiness = RecordingLibraryReadiness(providers: [{ self.store.libraryMigrationWorkState }])
        let coordinator = RecordingLocationCoordinator(store: store,
                                                       storage: storage,
                                                       readiness: readiness,
                                                       beforeFinalVerification: beforeFinalVerification)
        return (coordinator, defaults, suite)
    }

    func test_two_imports_hold_independent_tickets_until_their_own_settlement() async throws {
        let held = HeldReencode()
        heldReencoders.append(held)

        let firstSource = try makeSource("first.wav")
        let secondSource = try makeSource("second.wav")

        let first = Task { @MainActor in
            try await FileTranscriber.importFile(
                at: firstSource, into: self.store, title: "First",
                reencodeAudio: { source, destination in
                    try await held.reencode(source, destination)
                })
        }
        importTasks.append(first)
        try await held.waitUntilStarted(1)

        let secondDate = Date(timeIntervalSince1970: 1_000)
        let second = Task { @MainActor in
            try await FileTranscriber.importFile(
                at: secondSource, into: self.store,
                source: .microphone, title: "Second", createdAt: secondDate,
                voiceMemoUniqueID: "voice-1", voiceMemoFolderUUID: "folder-1",
                folder: "Imported",
                reencodeAudio: { source, destination in
                    try await held.reencode(source, destination)
                })
        }
        importTasks.append(second)
        try await held.waitUntilStarted(2)

        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 2)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertEqual(store.libraryMigrationWorkState.reason, "Library work is still running.")

        held.failNext()
        do {
            _ = try await first.value
            XCTFail("The injected reencode failure must throw")
        } catch {
            XCTAssertTrue(error is InjectedImportFailure)
        }

        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 1)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertTrue(store.recordings.isEmpty)

        var outstandingWhenPublished: Int?
        let observer = store.$recordings.dropFirst().sink { rows in
            if rows.count == 1, outstandingWhenPublished == nil {
                outstandingWhenPublished = self.store.libraryActivity.snapshot.outstandingCount
            }
        }
        defer { observer.cancel() }

        held.succeedNext(duration: 7.5)
        let recording = try await second.value

        XCTAssertEqual(outstandingWhenPublished, 1)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
        XCTAssertTrue(store.libraryMigrationWorkState.isIdle)
        XCTAssertEqual(store.recordings.map(\.id), [recording.id])
        XCTAssertEqual(recording.title, "Second")
        XCTAssertEqual(recording.duration, 7.5)
        XCTAssertEqual(recording.source, .microphone)
        XCTAssertEqual(recording.createdAt, secondDate)
        XCTAssertEqual(recording.folder, "Imported")
        XCTAssertEqual(recording.voiceMemoUniqueID, "voice-1")
        XCTAssertEqual(recording.voiceMemoFolderUUID, "folder-1")
        XCTAssertTrue(store.folders.contains("Imported"))
        XCTAssertEqual(store.recordings.count, 1)
        let audio = store.audioURL(for: recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try Data(contentsOf: audio), Data("synthetic audio".utf8))
    }

    func test_cancel_while_reencode_is_held_stays_busy_until_worker_returns() async throws {
        let held = HeldReencode()
        heldReencoders.append(held)

        let source = try makeSource("cancelled.wav")
        let task = Task { @MainActor in
            try await FileTranscriber.importFile(
                at: source, into: self.store, title: "Cancelled",
                reencodeAudio: { source, destination in
                    try await held.reencode(source, destination)
                })
        }
        importTasks.append(task)
        try await held.waitUntilStarted(1)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 1)

        task.cancel()
        await Task.yield()

        XCTAssertEqual(held.heldCount, 1)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 1)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertTrue(store.recordings.isEmpty)

        held.succeedNext(duration: 2.0)
        let recording = try await task.value

        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
        XCTAssertTrue(store.libraryMigrationWorkState.isIdle)
        XCTAssertEqual(store.recordings.map(\.id), [recording.id])
        XCTAssertEqual(recording.title, "Cancelled")
    }

    func test_separate_stores_do_not_share_import_tickets() async throws {
        let held = HeldReencode()
        heldReencoders.append(held)

        let otherRoot = base.appendingPathComponent("OtherStore", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherStore = RecordingStore(rootDirectory: otherRoot)

        let heldSource = try makeSource("held-a.wav")
        let otherSource = try makeSource("other-b.wav")
        let heldTask = Task { @MainActor in
            try await FileTranscriber.importFile(
                at: heldSource, into: self.store, title: "Held A",
                reencodeAudio: { source, destination in
                    try await held.reencode(source, destination)
                })
        }
        importTasks.append(heldTask)
        try await held.waitUntilStarted(1)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 1)

        let otherRecording = try await FileTranscriber.importFile(
            at: otherSource, into: otherStore, title: "Free B",
            reencodeAudio: { _, destination in
                try Data("other audio".utf8).write(to: destination)
                return 3.5
            })

        XCTAssertEqual(otherStore.recordings.map(\.id), [otherRecording.id])
        XCTAssertEqual(otherStore.libraryActivity.snapshot.outstandingCount, 0)
        XCTAssertTrue(otherStore.libraryMigrationWorkState.isIdle)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 1)
        XCTAssertFalse(store.libraryMigrationWorkState.isIdle)
        XCTAssertTrue(store.recordings.isEmpty)

        held.succeedNext(duration: 1.25)
        _ = try await heldTask.value
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
    }

    func test_chooser_entry_refuses_while_a_real_import_is_held() async throws {
        let held = HeldReencode()
        heldReencoders.append(held)

        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = try makeDestination("ChooserDestination")
        let oldDirectory = store.recordingsDirectory

        let source = try makeSource("chooser.wav")
        let task = Task { @MainActor in
            try await FileTranscriber.importFile(
                at: source, into: self.store, title: "Held",
                reencodeAudio: { source, destination in
                    try await held.reencode(source, destination)
                })
        }
        importTasks.append(task)
        try await held.waitUntilStarted(1)

        await coordinator.inspectSelection(destination)
        guard case .failure(let message) = coordinator.phase else {
            return XCTFail("\(coordinator.phase)")
        }
        XCTAssertTrue(message.contains("Finish"))
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL, oldDirectory.standardizedFileURL)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])

        held.succeedNext(duration: 1.0)
        _ = try await task.value
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
    }

    func test_transient_real_import_before_final_verification_invalidates_revision() async throws {
        let original = Recording(title: "Meeting", duration: 1, source: .microphone,
                                 audioFileName: "meeting.wav", status: .completed)
        store.add(original)
        try Data("original audio".utf8).write(to: store.recordingsDirectory.appendingPathComponent("meeting.wav"))
        let sourceIndex = try Data(contentsOf: root.appendingPathComponent("recordings.json"))
        let oldDirectory = store.recordingsDirectory
        let destination = try makeDestination("CopyDestination")
        let injectedSource = try makeSource("transient.wav")
        var beganBeforeActivation = false
        var failureObserved = false
        let (coordinator, defaults, suite) = makeCoordinator(beforeFinalVerification: {
            do {
                _ = try await FileTranscriber.importFile(
                    at: injectedSource, into: self.store, title: "Transient",
                    reencodeAudio: { _, _ in
                        beganBeforeActivation = self.store.recordingsDirectory == oldDirectory
                            && FileManager.default.fileExists(atPath: destination.appendingPathComponent("recordings.json").path)
                        throw InjectedImportFailure.reencode
                    })
                XCTFail("The injected import must fail before adding metadata")
            } catch {
                failureObserved = error as? InjectedImportFailure == .reencode
            }
        })
        defer { defaults.removePersistentDomain(forName: suite) }
        await coordinator.inspectSelection(destination)
        coordinator.select(.copy)
        await coordinator.continueSelection()
        await coordinator.awaitOperationSettled()
        XCTAssertTrue(beganBeforeActivation)
        XCTAssertTrue(failureObserved)
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
        XCTAssertEqual(store.recordings.map(\.id), [original.id])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recordings.json")), sourceIndex)
        guard case .failure = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(store.recordingsDirectory, oldDirectory)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func test_imported_pending_row_leaves_store_ready_but_source_inspection_still_refuses() async throws {
        let source = try makeSource("pending.wav")
        let recording = try await FileTranscriber.importFile(
            at: source, into: store, title: "Pending",
            reencodeAudio: { _, destination in
                try Data("pending audio".utf8).write(to: destination)
                return 1.0
            })

        XCTAssertEqual(recording.status, .pending)
        XCTAssertEqual(store.recordings.map(\.id), [recording.id])
        XCTAssertEqual(store.libraryActivity.snapshot.outstandingCount, 0)
        XCTAssertTrue(store.libraryMigrationWorkState.isIdle)

        let layout = try RecordingLibraryInspection.Layout(directory: store.recordingsDirectory,
                                                            defaultRoot: root)
        XCTAssertThrowsError(try RecordingLibraryInspection.inspect(layout)) { error in
            XCTAssertEqual(error as? RecordingLibraryInspection.Problem, .unsettledRecordings)
        }
    }
}

private enum InjectedImportFailure: Error, Equatable {
    case reencode
    case released
    case startTimedOut
}

@MainActor
private final class HeldReencode {
    private struct Pending {
        let destination: URL
        let continuation: CheckedContinuation<Result<Double, Error>, Never>
    }

    private var pending: [Pending] = []
    private var startWaiters: [(target: Int, expectation: XCTestExpectation)] = []
    private var released = false
    private(set) var startedCount = 0

    var heldCount: Int { pending.count }

    func reencode(_ source: URL, _ destination: URL) async throws -> Double {
        guard !released else { throw InjectedImportFailure.released }
        startedCount += 1
        let reached = startWaiters.filter { $0.target <= startedCount }
        startWaiters.removeAll { $0.target <= startedCount }
        for waiter in reached { waiter.expectation.fulfill() }
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Double, Error>, Never>) in
            pending.append(Pending(destination: destination, continuation: continuation))
        }
        return try result.get()
    }

    func waitUntilStarted(_ target: Int) async throws {
        guard startedCount < target else { return }
        let started = XCTestExpectation(description: "Import \(target) entered reencode")
        startWaiters.append((target, started))
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        startWaiters.removeAll { $0.expectation === started }
        guard result == .completed else { throw InjectedImportFailure.startTimedOut }
    }

    func failNext() {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        next.continuation.resume(returning: .failure(InjectedImportFailure.reencode))
    }

    func succeedNext(duration: Double, bytes: Data = Data("synthetic audio".utf8)) {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        do {
            try bytes.write(to: next.destination)
            next.continuation.resume(returning: .success(duration))
        } catch {
            next.continuation.resume(returning: .failure(error))
        }
    }

    func releaseAll() {
        released = true
        let all = pending
        pending.removeAll()
        for item in all {
            item.continuation.resume(returning: .failure(InjectedImportFailure.released))
        }
    }
}
