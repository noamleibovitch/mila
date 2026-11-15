import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

/// `PostRecordingCoordinator`'s calendar match: when it runs, what it writes,
/// and how it shares the title with the LLM auto-title job and with the user.
///
/// Every case injects `FakeCalendarProvider` and a `runLLM` stub, so nothing
/// here reads a real calendar or spawns a CLI.
@MainActor
final class CalendarMatchWiringTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var service: TranscriptionService!
    private var provider: FakeCalendarProvider!
    private var calendarSettings: CalendarSettings!
    private var llm: LLMSettings!
    private var llmCalls = 0
    private var suites: [String] = []

    private let work = CalendarInfo(id: "cal-work", title: "Work", sourceTitle: "Google")
    /// When every recording in this file stopped. The fake's events are laid
    /// out against it.
    private let stoppedAt = Date(timeIntervalSince1970: 1_700_001_800)
    private let defaultTitle = "Meeting · default"

    /// Bound for the transcript wait — see `PostRecordingCoordinatorSendTests`
    /// for why a test must not adopt the 600s production value.
    private static let testTranscriptWait: TimeInterval = 60

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "CalendarMatchWiringTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        service = TranscriptionService(
            store: store,
            modelManager: ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models")),
            diarizationSettings: DiarizationSettings(defaults: isolatedDefaults("diarization")),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "CalendarMatchWiringTests"),
            engine: StubWhisperEngine()
        )
        provider = FakeCalendarProvider(authorization: .fullAccess, calendars: [work])
        calendarSettings = CalendarSettings(defaults: isolatedDefaults("calendar"), provider: provider)
        await calendarSettings.setEnabled(true)
        calendarSettings.setCalendar(work.id, allowed: true)
        llm = LLMSettings(defaults: isolatedDefaults("llm"),
                          apiKeyKeychainKey: "CalendarMatchWiringTests.llm")
        llm.tool = .claude
        llm.nameGenerationEnabled = true
        llmCalls = 0
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        try await super.tearDown()
    }

    private func isolatedDefaults(_ label: String) -> UserDefaults {
        let suite = "CalendarMatchWiringTests.\(label)"
        UserDefaults().removePersistentDomain(forName: suite)
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func makeCoordinator(withCalendar: Bool = true) -> PostRecordingCoordinator {
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            calendar: withCalendar ? CalendarEventLookup(settings: calendarSettings) : nil,
            runLLM: { [weak self] _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                self?.llmCalls += 1
                return "An LLM Title"
            })
        coordinator.transcriptWaitTimeout = Self.testTranscriptWait
        return coordinator
    }

    /// A 30-minute recording that stopped at `stoppedAt`.
    private func addRecording(status: TranscriptionStatus = .completed,
                              text: String = "the transcript text") -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: "Meeting")
        try? Data("not-audio".utf8).write(to: audioURL)
        var rec = Recording(title: defaultTitle, createdAt: stoppedAt, duration: 30 * 60,
                            source: .meeting, audioFileName: audioURL.lastPathComponent,
                            fullText: text)
        rec.status = status
        store.add(rec)
        return rec
    }

    /// An event covering the whole recording.
    private func scheduleEvent(_ title: String = "Weekly sync") {
        provider.allEvents = [CalendarEventCandidate(
            title: title,
            start: stoppedAt.addingTimeInterval(-30 * 60), end: stoppedAt,
            calendarID: work.id, calendarName: "Work",
            attendees: [.init(name: "Dana", email: "dana@example.com"),
                        .init(name: "Room 4", email: "room4@example.com", kind: .room),
                        .init(name: "Me", email: "me@example.com", isCurrentUser: true)])]
    }

    private func stored(_ rec: Recording) -> Recording? {
        store.recordings.first { $0.id == rec.id }
    }

    private func waitFor(_ condition: @autoclosure () -> Bool,
                         timeoutSeconds: Double = 10,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeoutSeconds)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Long enough for a job that was going to run to have run.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Match

    func test_match_is_stored_and_titles_the_recording_without_an_llm_call() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.calendarEvent != nil)
        try await settle()

        let row = try XCTUnwrap(stored(rec))
        XCTAssertEqual(row.title, "Weekly sync")
        XCTAssertEqual(row.calendarEvent?.title, "Weekly sync")
        XCTAssertEqual(row.calendarEvent?.calendarName, "Work")
        XCTAssertEqual(row.calendarEvent?.attendees.map(\.name), ["Me", "Dana"])
        XCTAssertEqual(llmCalls, 0, "the calendar named it — no CLI call to pay for")
        XCTAssertEqual(provider.eventQueries.count, 1, "the match runs once")
        XCTAssertFalse(coordinator.autoSuggestingIDs.contains(rec.id))
    }

    func test_match_titles_the_recording_when_no_llm_is_configured() async throws {
        llm.tool = .none
        scheduleEvent()
        let coordinator = makeCoordinator()
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.title == "Weekly sync")
        XCTAssertNotNil(stored(rec)?.calendarEvent)
        XCTAssertEqual(llmCalls, 0)
    }

    // MARK: - LLM stays the fallback

    func test_no_matching_event_falls_back_to_the_llm_title() async throws {
        let coordinator = makeCoordinator()
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.title == "An LLM Title")
        XCTAssertNil(stored(rec)?.calendarEvent, "no match is nil, never a guess")
        XCTAssertEqual(llmCalls, 1)
        XCTAssertEqual(provider.eventQueries.count, 1)
    }

    func test_feature_off_reads_no_calendar_and_falls_back_to_the_llm_title() async throws {
        scheduleEvent()
        await calendarSettings.setEnabled(false)
        let coordinator = makeCoordinator()
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.title == "An LLM Title")
        XCTAssertNil(stored(rec)?.calendarEvent)
        XCTAssertTrue(provider.eventQueries.isEmpty)
    }

    func test_not_ready_reads_no_calendar() async throws {
        scheduleEvent()
        calendarSettings.setCalendar(work.id, allowed: false)   // on, access, nothing ticked
        let coordinator = makeCoordinator()
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.llmCalls == 1)
        XCTAssertNil(stored(rec)?.calendarEvent)
        XCTAssertTrue(provider.eventQueries.isEmpty)
    }

    func test_coordinator_without_a_lookup_behaves_as_before() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator(withCalendar: false)
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.title == "An LLM Title")
        XCTAssertNil(stored(rec)?.calendarEvent)
    }

    func test_untitled_event_is_stored_and_the_llm_titles_the_recording() async throws {
        scheduleEvent("  ")
        let coordinator = makeCoordinator()
        let rec = addRecording()

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.title == "An LLM Title")
        XCTAssertNotNil(stored(rec)?.calendarEvent, "the event is still the recording's event")
        XCTAssertEqual(llmCalls, 1)
    }

    // MARK: - A title the user typed is never overwritten

    func test_user_named_recording_keeps_its_title_and_still_gets_the_event() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        var rec = addRecording()
        rec.title = "Budget review with Dana"
        store.update(rec)

        coordinator.present(rec, titleWasUserProvided: true)
        try await waitFor(self.stored(rec)?.calendarEvent != nil)
        try await settle()

        XCTAssertEqual(stored(rec)?.title, "Budget review with Dana")
        XCTAssertEqual(stored(rec)?.calendarEvent?.title, "Weekly sync")
        XCTAssertEqual(llmCalls, 0)
    }

    /// The user renames in the sheet while transcription is still running;
    /// the match lands afterwards and must leave the name alone.
    func test_rename_before_the_match_lands_wins() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        let rec = addRecording(status: .running, text: "")

        coordinator.present(rec)
        try await settle()
        var current = try XCTUnwrap(stored(rec))
        XCTAssertNil(current.calendarEvent, "nothing is written while the row is still in flight")
        XCTAssertTrue(provider.eventQueries.isEmpty)

        current.title = "My own name"
        current.fullText = "the transcript text"
        current.status = .completed
        store.update(current)

        try await waitFor(self.stored(rec)?.calendarEvent != nil)
        try await settle()
        XCTAssertEqual(stored(rec)?.title, "My own name")
    }

    // MARK: - Timing

    func test_match_waits_for_the_offline_speaker_pass() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        let rec = addRecording()
        service.beginSpeakerFinalization(rec.id)

        coordinator.present(rec)
        try await settle()
        XCTAssertNil(stored(rec)?.calendarEvent)
        XCTAssertEqual(stored(rec)?.title, defaultTitle)

        service.endSpeakerFinalization(rec.id)
        try await waitFor(self.stored(rec)?.title == "Weekly sync")
        XCTAssertEqual(llmCalls, 0)
    }

    /// The wait gave up with transcription still running. Writing the row
    /// then is what the wait exists to prevent, so nothing is matched.
    func test_wait_timing_out_on_a_row_still_in_flight_writes_nothing() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        coordinator.transcriptWaitTimeout = 0.3
        let rec = addRecording(status: .running, text: "")

        coordinator.present(rec)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(stored(rec)?.calendarEvent)
        XCTAssertEqual(stored(rec)?.title, defaultTitle)
        XCTAssertTrue(provider.eventQueries.isEmpty)
    }

    /// A recording with no speech in it still happened during the meeting.
    func test_recording_with_an_empty_transcript_is_still_matched() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        let rec = addRecording(status: .failed, text: "")

        coordinator.present(rec)
        try await waitFor(self.stored(rec)?.title == "Weekly sync")
        XCTAssertEqual(llmCalls, 0)
    }

    func test_discarding_the_recording_cancels_the_match() async throws {
        scheduleEvent()
        let coordinator = makeCoordinator()
        let rec = addRecording(status: .running, text: "")

        coordinator.present(rec)
        try await Task.sleep(nanoseconds: 100_000_000)
        coordinator.cancelAndDiscard()
        try await settle()

        XCTAssertNil(stored(rec))
        XCTAssertTrue(provider.eventQueries.isEmpty)
        XCTAssertEqual(llmCalls, 0)
    }

    // MARK: - Persistence

    private func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func test_calendar_event_round_trips_and_is_absent_when_nil() throws {
        var rec = Recording(title: "t", createdAt: stoppedAt, source: .meeting, audioFileName: "a.wav")
        let bare = try JSONSerialization.jsonObject(with: storeEncoder().encode(rec)) as? [String: Any]
        XCTAssertNil(bare?["calendarEvent"], "no key when nil — byte-identical to before")

        let event = CalendarEventMatch(title: "Weekly sync",
                                       start: stoppedAt.addingTimeInterval(-1800), end: stoppedAt,
                                       calendarName: "Work",
                                       attendees: [.init(name: "Dana", email: "dana@example.com"),
                                                   .init(name: "Uri")])
        rec.calendarEvent = event
        let decoded = try storeDecoder().decode(Recording.self, from: storeEncoder().encode(rec))
        XCTAssertEqual(decoded.calendarEvent, event)
    }

    /// recordings.json loads all-or-nothing: an event this build cannot read
    /// must cost the event, not the library.
    func test_unreadable_calendar_event_is_dropped_without_failing_the_row() throws {
        let json = """
            {"id":"\(UUID().uuidString)","title":"t","createdAt":"2023-11-14T22:13:20Z",
             "duration":1,"source":"microphone","audioFileName":"a.wav","status":"completed",
             "language":"en","calendarEvent":{"title":"No dates","attendees":"nobody"}}
            """
        let rec = try storeDecoder().decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(rec.title, "t")
        XCTAssertNil(rec.calendarEvent)

        let sparse = """
            {"id":"\(UUID().uuidString)","title":"t","createdAt":"2023-11-14T22:13:20Z",
             "duration":1,"source":"microphone","audioFileName":"a.wav","status":"completed",
             "language":"en",
             "calendarEvent":{"start":"2023-11-14T21:43:20Z","end":"2023-11-14T22:13:20Z"}}
            """
        let lenient = try storeDecoder().decode(Recording.self, from: Data(sparse.utf8))
        XCTAssertEqual(lenient.calendarEvent?.title, "")
        XCTAssertEqual(lenient.calendarEvent?.attendees, [])
    }
}
