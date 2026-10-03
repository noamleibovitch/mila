import XCTest
import TranscriptionCore
@testable import Mila

/// Same public entry points as dictation and the saved-recording queue.
/// This regression runs against both the original and corrected service.
@MainActor
final class TranscriptionServiceShutdownTests: XCTestCase {
    func test_shutdown_rejects_new_one_shot_work() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanUp() }
        await fixture.service.shutdown()
        let segments = await fixture.service.transcribeOnceSegments(
            samples: Array(repeating: Float(0.2), count: 16_000),
            language: "en", audioCtx: 0)
        XCTAssertTrue(segments.isEmpty, "Shutdown must reject dictation/live work")
        let calls = await fixture.remote.calls
        XCTAssertEqual(calls, 0, "No remote transcription may start after shutdown")
        XCTAssertNil(fixture.service.lastError)
    }

    func test_shutdown_keeps_later_enqueued_recording_recoverable() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanUp() }
        let audioURL = fixture.store.recordingsDirectory.appendingPathComponent("shutdown.wav")
        try TestSupport.writeSineWav(at: audioURL)
        let recording = Recording(title: "Shutdown regression", source: .microphone,
                                  audioFileName: audioURL.lastPathComponent, status: .pending, language: "en")
        fixture.store.add(recording)
        await fixture.service.shutdown()
        fixture.service.enqueue(recording)
        await fixture.service.waitForIdle(timeout: 10)
        let calls = await fixture.remote.calls
        XCTAssertEqual(calls, 0, "Queue admission must close on shutdown")
        let saved = try XCTUnwrap(fixture.store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(saved.status, .pending, "Untouched queued audio must remain eligible for launch recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: saved).path))
        XCTAssertNil(fixture.service.lastError)
    }
}

@MainActor
private struct AdmissionFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingStore
    let remote: AdmissionProbeRemoteEngine
    let service: TranscriptionService

    init() throws {
        root = TestSupport.makeTempRoot(label: "ShutdownAdmission")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ShutdownAdmission.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = RecordingStore(rootDirectory: root)
        let settings = RemoteTranscriptionSettings(defaults: defaults,
                                                   apiKeyKeychainKey: suiteName + ".unused-key")
        settings.endpoint = "http://localhost:8080/v1"
        settings.model = "whisper-1"
        settings.backend = .remote
        remote = AdmissionProbeRemoteEngine()
        service = TranscriptionService(
            store: store,
            modelManager: ModelManager(modelsDirectory: root.appendingPathComponent("Models"), defaults: defaults),
            diarizationSettings: DiarizationSettings(defaults: defaults),
            remoteSettings: settings, engine: StubWhisperEngine(), remoteEngine: remote)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor AdmissionProbeRemoteEngine: RemoteTranscribing {
    private(set) var calls = 0
    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}
    func transcribe(samples: [Float], language: String, audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        calls += 1
        // Empty avoids unrelated post-success compression while demonstrating
        // that the original service has nevertheless started remote work.
        return []
    }
}
