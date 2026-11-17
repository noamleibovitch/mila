import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

/// The calendar match, driven through the real
/// `QuickActionsController.stopRecording` — the two ways a finished recording
/// used to miss it because it never reached the rename sheet:
///
///  * the Mac went to sleep, so the stop showed no sheet at all;
///  * the sheet was still open for the previous recording, so
///    `PostRecordingCoordinator.present` dropped this one.
///
/// `CalendarMatchWiringTests` covers the coordinator's rules; this file pins
/// that `stopRecording` reaches the coordinator on both paths.
@MainActor
final class CalendarMatchStopPathTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var postRecording: PostRecordingCoordinator!
    private var controller: QuickActionsController!
    private var provider: FakeCalendarProvider!

    private let suitePrefix = "CalendarMatchStopPathTests"
    private let suiteSuffixes = ["diarization", "language", "llm", "calendar"]
    private let work = CalendarInfo(id: "cal-work", title: "Work", sourceTitle: "Google")

    override func setUp() async throws {
        try await super.setUp()
        for suffix in suiteSuffixes {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: suitePrefix)
        try TestSupport.installFakeModel(into: manager)
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suitePrefix),
            engine: StubWhisperEngine())
        session = RecordingSession()

        // One event around "now": the recordings below are stamped with the
        // real clock by `stopRecording`.
        provider = FakeCalendarProvider(authorization: .fullAccess, calendars: [work], events: [
            CalendarEventCandidate(title: "Weekly sync",
                                   start: Date().addingTimeInterval(-3600),
                                   end: Date().addingTimeInterval(3600),
                                   calendarID: work.id, calendarName: "Work"),
        ])
        let calendar = CalendarSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).calendar")!,
                                        provider: provider)
        await calendar.setEnabled(true)
        calendar.setCalendar(work.id, allowed: true)

        // No LLM configured: any title change below is the calendar's.
        postRecording = PostRecordingCoordinator(
            store: store,
            transcription: service,
            llm: LLMSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).llm")!),
            calendar: CalendarEventLookup(settings: calendar))
        postRecording.transcriptWaitTimeout = 60
        controller = QuickActionsController(
            session: session,
            store: store,
            transcription: service,
            languageSettings: RecordingLanguageSettings(
                defaults: UserDefaults(suiteName: "\(suitePrefix).language")!),
            postRecording: postRecording)
    }

    override func tearDown() async throws {
        if session?.state != .idle { _ = await session?.stop() }
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for suffix in suiteSuffixes {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        try await super.tearDown()
    }

    private func freshWAV(_ name: String) throws -> URL {
        let url = store.freshAudioURL(suggestedName: name)
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        return url
    }

    private func row(for url: URL) -> Recording? {
        store.recordings.first { $0.audioFileName == url.lastPathComponent }
    }

    private func waitUntil(timeout: TimeInterval = 20,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func test_sleep_stopped_recording_gets_its_calendar_event() async throws {
        let url = try freshWAV("SleepStop")
        await controller.startFakeRecordingForTesting(outputURL: url)

        await controller.stopBecauseOfSleep()

        let saved = try XCTUnwrap(row(for: url))
        XCTAssertEqual(controller.sleepInterruption?.recordingID, saved.id,
                       "precondition: this was a sleep stop")
        XCTAssertNil(postRecording.pending, "a sleep stop shows no rename sheet")

        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        let matched = await waitUntil { self.row(for: url)?.calendarEvent != nil }
        XCTAssertTrue(matched, "a sleep-stopped recording must still be matched")
        XCTAssertEqual(row(for: url)?.calendarEvent?.title, "Weekly sync")
        XCTAssertEqual(row(for: url)?.title, "Weekly sync",
                       "and titled from the event, its title being the machine default")
    }

    func test_recording_stopped_while_the_previous_sheet_is_open_gets_its_calendar_event() async throws {
        let firstURL = try freshWAV("First")
        await controller.startFakeRecordingForTesting(outputURL: firstURL)
        await controller.stopRecording()
        let first = try XCTUnwrap(row(for: firstURL))
        XCTAssertEqual(postRecording.pending?.id, first.id, "precondition: the sheet is up for the first")
        await controller.awaitFinalizeTails()

        let secondURL = try freshWAV("Second")
        await controller.startFakeRecordingForTesting(outputURL: secondURL)
        await controller.stopRecording()
        XCTAssertNotNil(row(for: secondURL))
        XCTAssertEqual(postRecording.pending?.id, first.id,
                       "precondition: the second recording did not get the sheet")

        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        let matched = await waitUntil {
            self.row(for: secondURL)?.calendarEvent != nil && self.row(for: firstURL)?.calendarEvent != nil
        }
        XCTAssertTrue(matched, "both recordings must be matched, sheet or no sheet")
        XCTAssertEqual(row(for: secondURL)?.title, "Weekly sync")
    }
}
