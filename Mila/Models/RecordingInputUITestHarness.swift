#if DEBUG
import AVFoundation
import Foundation

/// Deterministic, bounded native-fixture harness for the live recording input
/// controls and meters.
///
/// `MilaApp` constructs this only when every UI-test isolation flag is present
/// (`--uitests`, `--ui-test-clean-store`, a UUID-owned storage suite, a
/// `--ui-test-recording-inputs=<scenario>` value and a validated
/// `Mila-UITest-<UUID>` 0700 clean root). It starts the app's existing
/// `QuickActionsController.startFakeRecordingForTesting` path and feeds
/// synthetic buffers through the REAL `RecordingSession.consumeMic` /
/// `consumeSystem` paths. No microphone, camera, ScreenCaptureKit stream,
/// TCC prompt, live transcription model, LLM or remote backend is opened.
///
/// The app-audio bring-up uses the recorders' existing `bringUpOverride` seam
/// so a native test can observe the real "Starting…" state while the bring-up
/// is held, or force the real permission-denied mapping. The hold gate is
/// per-instance, file-signalled and bounded; production and Release never
/// construct this type.
@MainActor
final class RecordingInputUITestHarness {
    enum Scenario: String {
        /// Microphone and app audio both accepted from the start.
        case bothIncluded = "both-included"
        /// Microphone only; app audio starts excluded and unopened.
        case microphoneOnly = "microphone-only"
        /// Both included for the RTL live-header layout fixture.
        case liveRTL = "live-rtl"

        var includesSystemInitially: Bool {
            self == .bothIncluded || self == .liveRTL
        }
    }

    static let launchArgumentPrefix = "--ui-test-recording-inputs="

    /// Retains the one fixture harness for the lifetime of this UI-test app
    /// process. The recorder's bring-up override and the feeding task hold it
    /// weakly so a completed fixture can still be released in ordinary DEBUG
    /// use; the app process itself owns every write it performs.
    private static var retained: RecordingInputUITestHarness?

    /// File markers the UI test owns inside the already-validated clean root.
    /// `deny` makes the requested app-audio leg fail with the real
    /// permission-denied path; `hold` parks the bring-up until `release`
    /// appears (or the bounded deadline expires).
    static let denyMarkerName = "Mila-UITest-recording-inputs-deny"
    static let holdMarkerName = "Mila-UITest-recording-inputs-hold"
    static let holdEnteredMarkerName = "Mila-UITest-recording-inputs-hold-entered"
    static let releaseMarkerName = "Mila-UITest-recording-inputs-release"

    private let scenario: Scenario
    private let root: URL
    private let actions: QuickActionsController
    private let session: RecordingSession
    private let store: RecordingStore

    private let micBuffer: AVAudioPCMBuffer
    private let systemBuffer: AVAudioPCMBuffer
    private var feedingTask: Task<Void, Never>?

    init(scenario: Scenario,
         root: URL,
         actions: QuickActionsController,
         session: RecordingSession,
         store: RecordingStore) {
        self.scenario = scenario
        self.root = root
        self.actions = actions
        self.session = session
        self.store = store
        self.micBuffer = Self.makeBuffer(amplitude: 0.8, frequency: 220)
        self.systemBuffer = Self.makeBuffer(amplitude: 0.4, frequency: 440)
    }

    /// Seeds every setting this fixture depends on into the UUID-owned suite
    /// before the app constructs its settings objects. Nothing is written to
    /// the user's standard defaults.
    static func prepareIsolatedDefaults(_ defaults: UserDefaults, scenario: Scenario) {
        defaults.set(false, forKey: "liveAI.transcribeWhileRecording")
        defaults.set(false, forKey: "liveAI.enabled")
        defaults.set(false, forKey: "liveAI.backgroundMode")
        defaults.set(false, forKey: "diarization.enabled")
        defaults.set(false, forKey: "meetingDetection.enabled")
        defaults.set(false, forKey: "speakers.voiceRecognition.enabled")
        defaults.set(false, forKey: "voiceMemos.enabled")
        defaults.set(false, forKey: "recordings.autoSave")
        defaults.set("local", forKey: "transcription.backend")
        defaults.set("none", forKey: "llm.tool")
        defaults.set(false, forKey: "llm.name.enabled")
        defaults.set(false, forKey: "llm.summary.enabled")
        defaults.set(false, forKey: "llm.action.enabled")
        defaults.set(scenario == .liveRTL ? "he" : "en", forKey: "recording.language")
    }

    func start() {
        Self.retained = self
        Task { await self.startRecording() }
    }

    private func startRecording() async {
        let outputURL = store.freshAudioURL(suggestedName: "Recording Inputs UI Test")
        await actions.startFakeRecordingForTesting(outputURL: outputURL, writeFile: true)
        guard actions.isRecording else { return }

        session.system.bringUpOverride = { [weak self] in
            guard let self else { return }
            try await self.awaitAppAudioBringUp()
        }

        if scenario.includesSystemInitially {
            _ = try? await session.setLiveSources(wantMic: true, wantSystem: true)
        }

        feedingTask = Task { [weak self] in
            guard let self else { return }
            await self.feedSyntheticBuffers()
        }
    }

    /// Runs on the main actor inside the existing app-audio bring-up seam.
    /// It either throws the recorder's real permission error or holds the
    /// bring-up on a bounded, file-signalled gate so the native test can
    /// inspect the truthful "Starting…" state.
    private func awaitAppAudioBringUp() async throws {
        let deny = root.appendingPathComponent(Self.denyMarkerName, isDirectory: false)
        if FileManager.default.fileExists(atPath: deny.path) {
            throw SystemAudioRecorder.CaptureError.permissionDenied
        }

        let hold = root.appendingPathComponent(Self.holdMarkerName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: hold.path) else { return }

        let entered = root.appendingPathComponent(Self.holdEnteredMarkerName, isDirectory: false)
        _ = FileManager.default.createFile(atPath: entered.path, contents: Data())

        let release = root.appendingPathComponent(Self.releaseMarkerName, isDirectory: false)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: release.path) {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func feedSyntheticBuffers() async {
        while !Task.isCancelled {
            if session.state == .recording {
                await session.consumeMic(micBuffer)
                if session.systemIncluded {
                    await session.consumeSystem(systemBuffer)
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private static func makeBuffer(amplitude: Float,
                                   frequency: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames: AVAudioFrameCount = 1_600
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let sample = Float(sin(Double(frame) * 2 * .pi * frequency / 16_000)) * amplitude
            buffer.floatChannelData![0][frame] = sample
        }
        return buffer
    }
}
#endif
