import XCTest
import Combine
import TranscriptionCore
@testable import Mila

@MainActor
final class DictationControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var hotkeys: HotkeySettings!
    private var defaultsSuite: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "DictationControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: "DictationControllerTests")
        defaultsSuite = UserDefaults(suiteName: "DictationControllerTests")
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"), defaults: defaultsSuite)
        try TestSupport.installFakeModel(into: manager, model: .ivritLarge)
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)
        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager, diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "DictationControllerTests.diarization")!), remoteSettings: TestSupport.isolatedRemoteSettings(label: "DictationControllerTests"), engine: stub)
        hotkeys = HotkeySettings(defaults: defaultsSuite)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        defaultsSuite.removePersistentDomain(forName: "DictationControllerTests")
        try await super.tearDown()
    }

    /// `transcribeOnce` must route Hebrew audio to the ivrit.ai model and
    /// English audio to the OpenAI turbo, even when a different model is
    /// "selected" globally. This is the dictation-language plumbing the new
    /// per-language hotkeys depend on.
    func test_transcribe_once_uses_language_specific_model() async {
        manager.setSelected(.ivritLarge)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "hello world")
        ])
        let samples = [Float](repeating: 0.05, count: 16_000)

        _ = await service.transcribeOnce(samples: samples, language: "en")

        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "English dictation must load the OpenAI turbo model")
    }

    func test_transcribe_once_routes_hebrew_to_ivrit_model() async {
        manager.setSelected(.openaiTurbo)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "שלום עולם")
        ])
        let samples = [Float](repeating: 0.05, count: 16_000)

        _ = await service.transcribeOnce(samples: samples, language: "he")

        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .ivritLarge).lastPathComponent,
                       "Hebrew dictation must load the ivrit.ai large-v3 model")
    }

    /// The TranscriptionService must forward `shutdown` to the engine. This
    /// is the fix path for the on-quit `ggml_abort` crash documented in the
    /// AppDelegate — without it, libc++ destroys the metal-device vector at
    /// `exit()` time before our context is freed.
    func test_shutdown_propagates_to_engine() async {
        await service.shutdown()
        let count = await stub.shutdownCount
        XCTAssertEqual(count, 1)
    }

    /// The ledger obligation "Dictation stop through persistence".
    ///
    /// The stop flips `state` to `.idle` before it saves, so `state` alone
    /// cannot prove the library is safe to relink; the ticket admitted by
    /// `stopAndTranscribe` is what must survive through the real `store.add`
    /// write. The stub engine's transcribe gate is the existing async seam:
    /// it holds the stop after that admission, then releases it into the
    /// unchanged persistence path. Empty canned segments keep the assertion
    /// off the Accessibility/paste path while still writing a real row and
    /// audio file.
    func test_stop_stays_busy_through_the_real_store_write_then_settles_idle_and_advances_generation() async throws {
        await stub.closeTranscribeGate()
        await stub.setDefaultCanned([])

        let liveTranscriber = LiveTranscriber(transcription: service)
        let controller = DictationController(store: store,
                                             transcription: service,
                                             hotkeySettings: hotkeys,
                                             liveTranscriber: liveTranscriber)
        controller.startFakeDictationForTesting(
            action: .dictateEnglish,
            samples: [Float](repeating: 0.05, count: 1_600))
        let beforeStop = controller.libraryWorkState
        XCTAssertFalse(beforeStop.isIdle, "sanity: the seeded dictation is in flight")

        var writeSnapshots: [(count: Int, state: DictationController.State,
                              idle: Bool, generation: UInt64)] = []
        let observation = store.$recordings
            .dropFirst()
            .sink { rows in
                writeSnapshots.append((rows.count,
                                       controller.state,
                                       controller.libraryWorkState.isIdle,
                                       controller.libraryWorkState.generation))
            }
        defer { observation.cancel() }

        let stop = Task { @MainActor in
            await controller.toggle(action: .dictateEnglish)
        }

        let entered = await waitUntil {
            let count = await stub.transcribeEnteredCount
            return count >= 1
        }
        guard entered else {
            await stub.openTranscribeGate()
            stop.cancel()
            XCTFail("the stop never reached the held transcribe seam")
            return
        }

        let held = controller.libraryWorkState
        XCTAssertEqual(controller.state, .transcribing(.dictateEnglish))
        XCTAssertFalse(held.isIdle, "the stop's ticket must hold readiness while transcribing")
        XCTAssertEqual(held.owner, "Dictation")
        XCTAssertEqual(held.generation, beforeStop.generation + 1,
                       "stop admission is one generation step while the work is held")

        await stub.openTranscribeGate()
        await stop.value

        XCTAssertEqual(controller.state, .idle)
        let settled = controller.libraryWorkState
        XCTAssertTrue(settled.isIdle)
        XCTAssertEqual(settled.generation, held.generation + 1,
                       "retirement must be the one final generation step")

        let write = try XCTUnwrap(writeSnapshots.last,
                                  "the dictation must reach the real store write")
        XCTAssertEqual(write.count, 1,
                       "the snapshot is the row the store is publishing at the write")
        XCTAssertEqual(write.state, .idle,
                       "state is already idle before persistence; only the ticket can hold readiness")
        XCTAssertFalse(write.idle,
                       "the ticket must still be outstanding at the real store write")
        XCTAssertEqual(write.generation, held.generation,
                       "the write happens inside the admitted, not yet retired, ownership")

        XCTAssertEqual(store.recordings.count, 1)
        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.source, .microphone)
        XCTAssertEqual(saved.audioFileName.hasSuffix(".wav"), true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.audioURL(for: saved).path),
            "the real persistence path must have written the dictation audio")
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
