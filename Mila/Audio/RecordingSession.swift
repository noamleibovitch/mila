import Foundation
import AVFoundation
import Combine
import OSLog
import os
import ScreenCaptureKit
import TranscriptionCore

private let recLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "RecordingSession")

/// Orchestrates microphone + system audio capture into a single mono 16kHz WAV file.
@MainActor
final class RecordingSession: ObservableObject {
    enum State { case idle, recording, paused, stopping }
    @Published private(set) var state: State = .idle

    /// The live readouts — elapsed clock and the two level meters — on their
    /// own `ObservableObject`, deliberately NOT `@Published` here.
    ///
    /// They change at audio-buffer cadence: `micLevel` per mic tap buffer
    /// (~12 Hz), `systemLevel` per ScreenCaptureKit buffer (up to ~50 Hz),
    /// `elapsed` at 5 Hz. When they were `@Published` on this object every
    /// one of those ticks re-published `RecordingSession` — and this object
    /// is a `@StateObject` on `MilaApp`, so each publish re-evaluated the
    /// App's `body` and re-diffed the whole scene: the window root view, the
    /// sidebar outline view, even the main menu. A `sample` of a recording
    /// put 81% of main-thread time inside that SwiftUI update, i.e. 60–75%
    /// CPU for the recording alone, on the remote backend with nothing local
    /// to transcribe (#280).
    ///
    /// Views that show the clock or a meter observe `meters` directly (it is
    /// injected as its own environment object). The passthroughs below keep
    /// the synchronous readers — the silence watchdog, `stopRecording`'s
    /// duration snapshot, the tests — working unchanged; reading them does
    /// not subscribe to anything.
    let meters = RecordingMeters()
    var elapsed: TimeInterval { meters.elapsed }
    var micLevel: Float { meters.micLevel }
    var systemLevel: Float { meters.systemLevel }

    let mic = MicrophoneRecorder()
    let system = SystemAudioRecorder()

    private(set) var source: RecordingSource = .microphone

    // MARK: - Live source inclusion (mic/app toggles during a recording)

    /// Accepted live inclusion of each capture leg. `source` above stays the
    /// INITIAL metadata for the whole recording (title, saved
    /// `Recording.source`, stop-time diagnostics); live routing keys on these
    /// booleans plus `micLegOpened` / `systemLegOpened`, never on the enum.
    ///
    /// Low-frequency by construction: only `setLiveSources` and the
    /// start/stop lifecycle write them, so publishing them here cannot put
    /// the session on the audio cadence that #280 removed.
    @Published private(set) var micIncluded = false
    @Published private(set) var systemIncluded = false
    @Published private(set) var micStarting = false
    @Published private(set) var systemStarting = false
    /// Set when the most recent explicit bring-up of that leg failed. Cleared
    /// by the next enable request (at its start) or by a successful one.
    @Published private(set) var micUnavailable = false
    @Published private(set) var systemUnavailable = false
    /// Low-frequency in-flight flag for the serialized source change. The
    /// controller disables both switches while this is true.
    @Published private(set) var isChangingLiveSources = false
    /// True once the accepted inclusion actually changed during this
    /// recording. In-memory only — no schema/metadata change. The controller
    /// reads it to suppress the short-capture warning for a deliberately
    /// narrowed recording.
    @Published private(set) var legsChangedDuringRecording = false
    /// True only when the session is `.paused` because BOTH sources are
    /// excluded. Re-enabling a source auto-resumes this pause only; a manual
    /// pause is never resumed by a toggle.
    @Published private(set) var autoPausedBySourceState = false
    /// Why the most recent `resume()` was refused, for the controller to read
    /// out. `nil` once a resume succeeds or a new recording starts.
    @Published private(set) var lastResumeRefusal: ResumeRefusal?

    /// Whether the leg's capture engine has ever been opened for this
    /// recording. A muted leg can stay open for clock/watchdog purposes; an
    /// `off` leg has never been opened. Distinct from `isRunning`, which a
    /// fake test session never sets.
    private(set) var micLegOpened = false
    private(set) var systemLegOpened = false

    /// Monotonic generation for live reconfiguration. Bumped at the start of
    /// every accepted `setLiveSources`, and by `start`/`stop`/`cancelAll`
    /// BEFORE teardown. An in-flight leg bring-up captures the value it began
    /// with and refuses to publish anything after it changes.
    ///
    /// Deliberately separate from `captureEpoch`: that one means "a new
    /// recording began" and drives live-pipeline resume detection; it must
    /// not move on a mere source toggle, pause or stop.
    private(set) var liveConfigGeneration = 0
    private var liveChangeCancellation: CaptureStartCancellation?
    private var liveChangeTask: Task<LegBringUpOutcome, Never>?
    /// `cancelAll()` keeps its historical state-transition behavior (no
    /// `.stopping` publish at terminate), so this private flag is what makes
    /// `setLiveSources` refuse a reconfiguration racing teardown.
    private var isCancellingAll = false

    /// Per-leg result of a bring-up performed inside `setLiveSources`.
    private struct LegBringUpOutcome: Sendable {
        var micStarted = false
        var systemStarted = false
        var micError: LiveSourceChangeError?
        var systemError: LiveSourceChangeError?
        var cancelled = false
    }

    /// Why an explicit resume was refused. Readable for the controller so it
    /// can explain it inline rather than silently no-op'ing.
    enum ResumeRefusal: Equatable, Sendable {
        case bothSourcesExcluded

        var message: String {
            switch self {
            case .bothSourcesExcluded:
                return "Turn on the microphone or app audio to resume."
            }
        }
    }

    /// Bounded, per-leg failure of a live source change. The controller maps
    /// permission cases onto its existing permission flags and everything
    /// else onto a concise recording error.
    enum LiveSourceChangeError: LocalizedError, Equatable, Sendable {
        case noActiveRecording
        case changeInFlight
        case microphonePermissionDenied
        case microphoneUnavailable(String)
        case systemAudioPermissionDenied
        case systemAudioUnavailable(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noActiveRecording:
                return "No recording is active."
            case .changeInFlight:
                return "A microphone or app-audio change is already in progress."
            case .microphonePermissionDenied:
                return "Microphone access is required to include the microphone."
            case .microphoneUnavailable(let detail):
                return detail
            case .systemAudioPermissionDenied:
                return "Screen & System Audio Recording permission is required to include app audio."
            case .systemAudioUnavailable(let detail):
                return detail
            case .cancelled:
                return "The microphone or app-audio change was cancelled."
            }
        }
    }

    /// UI-facing per-leg state, derived from the accepted inclusion and
    /// whether the engine was ever opened. The global `.paused` state is
    /// separate; the leaf combines the two (a clocking-but-excluded mic reads
    /// `muted`, never `off`).
    enum LiveLegState: Equatable, Sendable {
        case off
        case muted
        case starting
        case listening
        case unavailable
    }

    var micLiveState: LiveLegState {
        if micStarting { return .starting }
        if micUnavailable && !micIncluded { return .unavailable }
        if micIncluded { return (isFakeForTesting || mic.isRunning) ? .listening : .unavailable }
        return micLegOpened ? .muted : .off
    }

    var systemLiveState: LiveLegState {
        if systemStarting { return .starting }
        if systemUnavailable && !systemIncluded { return .unavailable }
        if systemIncluded { return (isFakeForTesting || system.isRunning) ? .listening : .unavailable }
        return systemLegOpened ? .muted : .off
    }

    /// Read-only snapshot for the controller/leaf. The individual published
    /// properties above are the observation points; this is just the
    /// convenience bundle the next slice needs.
    struct LiveSourceSnapshot: Equatable, Sendable {
        var micIncluded: Bool
        var systemIncluded: Bool
        var micOpened: Bool
        var systemOpened: Bool
        var micStarting: Bool
        var systemStarting: Bool
        var micUnavailable: Bool
        var systemUnavailable: Bool
        var isChanging: Bool
        var isAutoPaused: Bool
        var legsChanged: Bool
        var micState: LiveLegState
        var systemState: LiveLegState
    }

    var liveSourceSnapshot: LiveSourceSnapshot {
        LiveSourceSnapshot(
            micIncluded: micIncluded,
            systemIncluded: systemIncluded,
            micOpened: micLegOpened,
            systemOpened: systemLegOpened,
            micStarting: micStarting,
            systemStarting: systemStarting,
            micUnavailable: micUnavailable,
            systemUnavailable: systemUnavailable,
            isChanging: isChangingLiveSources,
            isAutoPaused: autoPausedBySourceState,
            legsChanged: legsChangedDuringRecording,
            micState: micLiveState,
            systemState: systemLiveState
        )
    }

    /// Mic frames captured by the most recent recording, snapshotted at
    /// `stop()` before the engine is torn down. 0 for a mic/meeting recording
    /// means the microphone produced nothing — read by the caller to surface
    /// an actionable message instead of a silent "failed" recording.
    private(set) var lastMicFrameCount: Int = 0
    /// True only for a UI-test session started via `startFakeForTesting`.
    /// Read by `stop()` so it doesn't snapshot a 0 mic-frame count (the fake
    /// session never starts the real mic) — otherwise `stopRecording` would
    /// trip its empty-mic `lastError` alert and pop a blocking modal over
    /// the UI test.
    private var isFakeForTesting = false
    /// Path of the WAV currently being written. `nil` while idle. The live
    /// streaming consumers (LiveSpeakerDiarizer) read partial frames out of
    /// this file while we're still appending to it — safe because
    /// `AVAudioFile` writes the WAV header on construction and frames are
    /// appended without rewriting earlier bytes.
    private(set) var fileURL: URL?
    private var audioFile: AVAudioFile?
    private var startTime: Date?
    /// Wall-clock instant the current recording began, pauses included. nil
    /// when nothing is being recorded; read it before `stop()`.
    var startedAt: Date? { startTime }
    /// Wall-clock instant the current pause began. `nil` unless
    /// `state == .paused`. Used to accumulate `totalPaused` on resume so
    /// `elapsed` never counts paused time.
    private var pausedAt: Date?
    /// Total wall-clock time spent paused so far this session. Subtracted
    /// from the raw `now - startTime` so `elapsed` reflects only the audio
    /// that actually made it into the WAV (paused spans are dropped by the
    /// capture-gate in `consumeMic` / `consumeSystem`), keeping `elapsed`
    /// aligned with both the on-disk duration and the live segment
    /// timestamps.
    private var totalPaused: TimeInterval = 0
    /// Monotonic id for the current capture, bumped by `start()` /
    /// `startFakeForTesting()` and by nothing else — in particular NOT by
    /// `pause()` / `resume()`.
    ///
    /// Exists so a `$state` observer can tell "a brand-new recording began"
    /// from "the same recording came back from a pause" WITHOUT having to
    /// see every intermediate state. That distinction can't be made by
    /// remembering the previously-observed state: `@Published` drops values
    /// published while its `.values` async consumer has no outstanding
    /// demand, so a quick pause→resume (a double-tap on the Pause button, or
    /// a hotkey pressed twice) can surface to the observer as a bare second
    /// `.recording` with the `.paused` in between never delivered. Treating
    /// that as a new recording re-runs live-pipeline setup and
    /// `transcriber.start()` wipes `segments` / `fullText` — the whole
    /// transcript the user has been reading.
    private(set) var captureEpoch: Int = 0
    private var timerTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?

    /// Jitter buffer for system audio in meeting mode. The mic is the
    /// master clock (it delivers continuously at 16kHz); each mic chunk in
    /// `consumeMic` pulls an equal span of system audio out of here and
    /// mixes the two. ScreenCaptureKit only delivers system buffers while
    /// sound is actually playing, so this drains to empty during quiet
    /// stretches — the mix just falls back to mic-only for that span, which
    /// is why the live feed never starves the way the old mic/system
    /// pairing did.
    private var pendingSystem: [Float] = []
    /// Cap on the system jitter buffer (~30s @ 16kHz). Generous so normal SCK
    /// bursts / clock skew just *delay* app audio (the mic clock catches back
    /// up) instead of losing it; only a genuinely stuck mic clock reaches the
    /// cap, and `consumeSystem` logs when it trims so the loss isn't silent.
    private let maxPendingSystem = Int(WhisperAudioFormat.sampleRate) * 30
    /// Count of overflow flushes this recording — used to throttle the
    /// overflow log line (a stall arrives as thousands of ~320-sample SCK
    /// buffers; logging each one buried a diagnostic bundle in ~3k
    /// identical lines).
    private var overflowFlushesSinceStart = 0
    private let writeQueue = DispatchQueue(label: "io.island.mila.recording-write")

    /// Fired with each post-mix sample chunk so the live transcriber
    /// (and any other realtime consumer) can stream during recording.
    /// We deliberately don't also retain a full-recording PCM buffer
    /// here — `LiveTranscriber` keeps its own rolling window, and the
    /// authoritative on-disk copy is the WAV we write per-chunk via
    /// `writer`. (Earlier versions kept a duplicate `liveSamples`
    /// array that was never read; removed in PR #20 after Bugbot
    /// flagged the second full-length in-memory copy.)
    var onLiveSamples: ((ArraySlice<Float>) -> Void)?

    func refreshSystemAudioApps() async {
        await system.refreshShareableContent()
    }

    func selectApp(_ app: SCRunningApplication?) {
        system.selectedApp = app
    }

    /// Initial per-leg inclusion for a recording: the `source` enum describes
    /// what the user asked for at start and stays the recording's metadata.
    /// Live changes after this point move the booleans, never `source`.
    static func initialInclusion(for source: RecordingSource) -> (mic: Bool, system: Bool) {
        switch source {
        case .microphone, .voiceMemo:
            return (mic: true, system: false)
        case .systemAudio:
            return (mic: false, system: true)
        case .meeting:
            return (mic: true, system: true)
        }
    }

    /// The one WAV writer configuration, shared by the real `start` and the
    /// test-only fake start so saved-WAV assertions exercise the same path.
    private func makeAudioFile(at outputURL: URL) throws -> AVAudioFile {
        let format = WhisperAudioFormat.pcmFloat32
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try AVAudioFile(forWriting: outputURL, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Reset every in-memory live-source flag. Called at start (then the
    /// initial inclusion is applied), and at teardown so a new recording
    /// never inherits an unavailable leg, an auto-pause, a resume refusal or
    /// a "legs changed" marker from the previous one.
    private func resetLiveSourceState() {
        micIncluded = false
        systemIncluded = false
        micStarting = false
        systemStarting = false
        micUnavailable = false
        systemUnavailable = false
        isChangingLiveSources = false
        legsChangedDuringRecording = false
        autoPausedBySourceState = false
        lastResumeRefusal = nil
        micLegOpened = false
        systemLegOpened = false
        liveChangeCancellation = nil
        liveChangeTask = nil
        isCancellingAll = false
    }

    /// Thrown when `start`'s caller-supplied `isStillValid` predicate turns
    /// false during the async bring-up (e.g. a per-app prompt was revoked or
    /// superseded while the permission or engine handshake was in flight).
    /// The partial session has already been torn down by the time this
    /// reaches the caller, so it is not a user-visible failure.
    struct StartCancelled: Error {}
    private var startInFlight = false

    /// Start capture. `isStillValid` is re-checked after every await that can
    /// span a user decision (mic permission, mic engine start, system-audio
    /// start) and immediately before `.recording` is published; when it
    /// returns false the partial session is torn down through the existing
    /// failure teardown and `StartCancelled` is thrown, so no recording is
    /// published for a superseded prompt. Manual callers keep the default
    /// always-true predicate and observe identical behavior.
    ///
    /// `cancellation` is handed to each capture leg's bring-up, which throws
    /// `CaptureStartCancellation.Cancelled` rather than open capture once it
    /// is tripped; the partial-bring-up teardown below then runs as for any
    /// other failure (#328). Both arguments are defaulted, so a manual start
    /// that passes neither behaves exactly as it did before.
    func start(source: RecordingSource, outputURL: URL,
               isStillValid: () -> Bool = { true },
               cancellation: CaptureStartCancellation? = nil) async throws {
        guard state == .idle else { return }
        guard !startInFlight, isStillValid() else { throw StartCancelled() }
        startInFlight = true
        defer { startInFlight = false }
        let fileAlreadyExisted = FileManager.default.fileExists(atPath: outputURL.path)
        self.source = source
        self.fileURL = outputURL
        self.writesSinceStart = 0
        self.systemBuffersSinceStart = 0
        self.overflowFlushesSinceStart = 0
        self.isFakeForTesting = false
        self.lastMicFrameCount = 0
        liveConfigGeneration += 1
        resetLiveSourceState()
        let initial = Self.initialInclusion(for: source)
        micIncluded = initial.mic
        systemIncluded = initial.system
        micLegOpened = initial.mic
        systemLegOpened = initial.system
        // Never inherit a stale system-audio tail from the previous
        // recording: a `consumeSystem` call that was already dequeued when
        // the last stop() ran its flush can append to `pendingSystem`
        // after the flush, and stop() doesn't clear the buffer.
        pendingSystem.removeAll(keepingCapacity: false)

        do {
            self.audioFile = try makeAudioFile(at: outputURL)

            if source == .microphone || source == .meeting {
                _ = await mic.requestAccess()
                if !isStillValid() {
                    throw StartCancelled()
                }
                try await mic.start(cancellation: cancellation)
                if !isStillValid() {
                    throw StartCancelled()
                }
                micTask = Task { [weak self] in
                    guard let self else { return }
                    for await buf in self.mic.audioStream {
                        await self.consumeMic(buf)
                    }
                }
            }

            if source == .systemAudio || source == .meeting {
                try await system.start(cancellation: cancellation)
                if !isStillValid() {
                    throw StartCancelled()
                }
                systemTask = Task { [weak self] in
                    guard let self else { return }
                    for await buf in self.system.audioStream {
                        await self.consumeSystem(buf)
                    }
                }
            }
        } catch {
            // A partial bring-up must not leak. Without this teardown, a
            // meeting-mode start whose system leg throws (typically Screen
            // Recording permission denied) left the mic engine hot and the
            // WAV file open, appending mic audio indefinitely — and since
            // `state` is still .idle, `cancelAll()` refused to clean it up.
            // `AVAudioFile(forWriting: outputURL, …)` is inside this `do`, so
            // the failure being reported can be "couldn't create the recording
            // file" — and `outputURL` is `freshAudioURL`, a title-derived name
            // inside the user's chosen recordings folder, both of which Cocoa
            // quotes in `localizedDescription`. The far more common failure
            // here (Screen Recording permission denied) is fully described by
            // the source + domain + code, which stay public. (Issue #213.)
            await teardownPartialStart()
            if error is StartCancelled {
                if !fileAlreadyExisted { try? FileManager.default.removeItem(at: outputURL) }
                throw error
            }
            let ns = error as NSError
            if error is CaptureStartCancellation.Cancelled {
                // Deliberate (sleep / lock during Starting…, #328), not a
                // bring-up failure — keep it out of the error-level lines a
                // diagnostic report is triaged by. The WAV this attempt
                // created is removed unless it pre-existed.
                if !fileAlreadyExisted { try? FileManager.default.removeItem(at: outputURL) }
                recLog.log("start(\(source.rawValue, privacy: .public)) cancelled before capture opened — tearing down partial session")
                throw error
            }
            recLog.error("""
                start(\(source.rawValue, privacy: .public)) failed mid-bring-up \
                — tearing down partial session \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
            throw error
        }

        // Final validity gate before this attempt publishes `.recording`. The
        // per-leg checks above already cover the awaited bring-up; this closes
        // the window between the last one and the state flip, so a consent
        // revocation that landed after the final leg still tears the partial
        // session down instead of being announced as a live recording.
        if !isStillValid() {
            await teardownPartialStart()
            if !fileAlreadyExisted { try? FileManager.default.removeItem(at: outputURL) }
            throw StartCancelled()
        }

        startTime = Date()
        pausedAt = nil
        totalPaused = 0
        captureEpoch += 1
        state = .recording
        startElapsedTimer()
    }

    /// Tear down whatever a failed or cancelled `start` had already brought
    /// up. Shared by the error path and the `isStillValid` cancellation path:
    /// cancels the consumer tasks, stops both engines, and drops the
    /// half-created WAV so `state` returns cleanly to `.idle`. Idempotent —
    /// safe to call after only some of the legs started.
    private func teardownPartialStart() async {
        liveConfigGeneration += 1
        liveChangeCancellation?.cancel()
        liveChangeCancellation = nil
        liveChangeTask = nil
        micTask?.cancel(); micTask = nil
        systemTask?.cancel(); systemTask = nil
        await mic.stop()
        await system.stop()
        audioFile = nil
        fileURL = nil
        pendingSystem.removeAll(keepingCapacity: false)
        resetLiveSourceState()
    }

    /// Drives the `elapsed` clock while a session is active. Kept running
    /// across pauses (`state == .paused`) but only advances the published
    /// value while `.recording`, so a pause freezes the timer instead of
    /// letting it jump forward by the paused span on resume.
    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while let self, self.state == .recording || self.state == .paused {
                if self.state == .recording, let start = self.startTime {
                    self.meters.elapsed = Self.elapsed(now: Date(), startTime: start,
                                                       totalPaused: self.totalPaused)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Pure elapsed-time computation: raw wall clock since `startTime`
    /// minus the time already spent paused. Factored out so the
    /// pause-accounting math is unit-testable without an audio engine.
    static func elapsed(now: Date, startTime: Date, totalPaused: TimeInterval) -> TimeInterval {
        max(0, now.timeIntervalSince(startTime) - totalPaused)
    }

    /// Suspend capture without tearing down the engine. While paused,
    /// `consumeMic` / `consumeSystem` drop every incoming buffer, so nothing
    /// is written to the WAV or forwarded to the live transcriber — the
    /// paused span is genuinely absent from the recording.
    ///
    /// The mic / system-audio engines keep RUNNING (we just discard their
    /// output) rather than stopping. Two reasons:
    ///
    ///  1. It avoids a fresh-engine-per-resume bring-up, which is the
    ///     fragile part of capture (see `MicrophoneRecorder`'s notes on
    ///     CoreAudio stalling for seconds on a wireless mic profile switch).
    ///  2. It keeps `MicrophoneRecorder`'s stall watchdog honest. That
    ///     watchdog rebuilds the engine when `MicFrameStats.frames` stops
    ///     growing — but that counter is incremented **inside the audio tap**,
    ///     upstream of the paused gate below, so it keeps advancing for the
    ///     whole pause and the watchdog never sees a flatline. Stopping the
    ///     engine here, or gating the tap instead of gating downstream, would
    ///     make a pause look exactly like a dead input device and hand the
    ///     watchdog a rebuild it must not perform.
    ///
    /// The watchdog is deliberately left ARMED across a pause: if the input
    /// device really does die while paused, we want it repaired before the
    /// user resumes, not four seconds after.
    func pause() async {
        guard state == .recording, !isCancellingAll else { return }
        // An explicit Pause is never an auto-pause: even if both sources are
        // excluded, re-enabling one later must not resume this session.
        autoPausedBySourceState = false
        await performPause()
    }

    /// The shared pause work. `pause()` calls this for a user-requested
    /// pause; `setLiveSources` calls it when both sources are turned off and
    /// marks `autoPausedBySourceState` first.
    private func performPause() async {
        pausedAt = Date()
        // Flip the gate FIRST so nothing else lands in `pendingSystem` while
        // the flush below awaits.
        state = .paused
        // Meeting mode / app-only-under-the-mic-clock parks system audio here
        // for the mic clock to consume. Whatever is parked at the pause
        // instant is audio the other side already produced BEFORE the pause,
        // so write it out (system-only, at full scale — exactly what `stop()`
        // does with the same tail) instead of discarding it. Discarding is
        // normally a sub-100ms loss, but the buffer holds up to 30s when the
        // mic clock is stalled (display sleep/wake), and losing half a minute
        // of the other side of a meeting to a Pause tap is not a trade the
        // user agreed to.
        await flushPendingSystemTail()
        // The meters are driven from `consumeMic` / `consumeSystem`, which
        // stop running now — without this they'd sit frozen at their last
        // pre-pause reading and read as "still listening".
        meters.micLevel = 0
        meters.systemLevel = 0
        recLog.log("pause: source=\(self.source.rawValue, privacy: .public) elapsed=\(self.elapsed, privacy: .public) auto=\(self.autoPausedBySourceState, privacy: .public)")
    }

    /// Resume a paused session. Accumulates the just-finished pause into
    /// `totalPaused` so `elapsed` skips it, and clears any system audio that
    /// slipped in while paused before capture resumes.
    ///
    /// Returns whether the session actually resumed. An explicit resume while
    /// both sources are excluded is refused — there would be nothing to
    /// capture — and `lastResumeRefusal` carries the readable cause for the
    /// controller. `@discardableResult` keeps the existing callers unchanged.
    @discardableResult
    func resume() -> Bool {
        guard state == .paused, !isCancellingAll else { return false }
        guard micIncluded || systemIncluded else {
            lastResumeRefusal = .bothSourcesExcluded
            recLog.log("resume refused: both sources are excluded")
            return false
        }
        if let pausedAt {
            totalPaused += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        // `consumeSystem` checks the state gate and then awaits before
        // appending, so a buffer that passed the gate just as `pause()` ran
        // can still land in the buffer afterwards. Anything sitting here now
        // is therefore either that straggler or a leftover the pause flush
        // raced — either way it predates the gap, and mixing it into the
        // post-resume audio would glue the two sides of the pause together
        // with the gap collapsed out. Drop it.
        pendingSystem.removeAll(keepingCapacity: false)
        state = .recording
        autoPausedBySourceState = false
        lastResumeRefusal = nil
        recLog.log("resume: source=\(self.source.rawValue, privacy: .public) totalPaused=\(self.totalPaused, privacy: .public)")
        return true
    }

    /// UI-test seam: flip state to .recording without spinning up
    /// AVAudioEngine. The caller (a launch-arg-driven injection task
    /// in `MilaApp.init`) is responsible for pushing samples into
    /// `onLiveSamples` to drive the rest of the pipeline. Avoids
    /// depending on a real microphone (or a CI-flaky virtual loopback
    /// like BlackHole) for the audio-capture E2E.
    ///
    /// Stop is the same as the real flow: caller invokes `stop()` and
    /// gets back the (possibly nil) outputURL.
    /// `writeFile` is a test-only seam: the default `false` keeps the
    /// historical behavior (no `AVAudioFile`; injected samples never hit
    /// disk). Passing `true` opens the SAME writer configuration the real
    /// `start` uses, so source-toggle tests can assert actual saved WAV
    /// samples through the real `write` path on test-owned temp files. The
    /// production path is untouched.
    func startFakeForTesting(outputURL: URL, writeFile: Bool = false) async {
        guard state == .idle else { return }
        self.source = .microphone
        self.fileURL = outputURL
        self.writesSinceStart = 0
        self.systemBuffersSinceStart = 0
        self.overflowFlushesSinceStart = 0
        self.isFakeForTesting = true
        self.lastMicFrameCount = 0
        liveConfigGeneration += 1
        resetLiveSourceState()
        let initial = Self.initialInclusion(for: .microphone)
        micIncluded = initial.mic
        systemIncluded = initial.system
        micLegOpened = initial.mic
        systemLegOpened = initial.system
        pendingSystem.removeAll(keepingCapacity: false)
        if writeFile {
            audioFile = try? makeAudioFile(at: outputURL)
        } else {
            // Skip AVAudioFile setup — the test injects samples directly
            // into onLiveSamples; nothing should be writing to disk.
            audioFile = nil
        }
        startTime = Date()
        pausedAt = nil
        totalPaused = 0
        captureEpoch += 1
        state = .recording
        startElapsedTimer()
    }

    func stop() async -> URL? {
        guard state == .recording || state == .paused else { return fileURL }
        // Invalidate any in-flight reconfiguration BEFORE teardown, then wait
        // for that leg bring-up to finish. The generation bump makes its
        // continuation refuse to publish; awaiting it here means a late
        // `mic.start`/`system.start` can never install capture after we tore
        // down (or touch a following recording's engine).
        liveConfigGeneration += 1
        liveChangeCancellation?.cancel()
        let inFlight = liveChangeTask
        state = .stopping
        if let inFlight { _ = await inFlight.value }
        // Snapshot the mic frame count BEFORE teardown so the caller can tell
        // a genuinely-empty mic session apart from a normal one. A fake
        // UI-test session never started the real mic, so report a non-zero
        // sentinel to keep `stopRecording` from tripping its empty-mic alert.
        let micFrames = isFakeForTesting ? 1 : mic.capturedFrameCount
        lastMicFrameCount = micFrames
        await mic.stop()
        await system.stop()
        micTask?.cancel(); micTask = nil
        systemTask?.cancel(); systemTask = nil
        timerTask?.cancel(); timerTask = nil

        await flushPendingSystemTail()
        recLog.log("stop: source=\(self.source.rawValue, privacy: .public) micFrames=\(micFrames, privacy: .public) systemBuffers=\(self.systemBuffersSinceStart, privacy: .public) writes=\(self.writesSinceStart, privacy: .public)")
        if (source == .microphone || source == .meeting) && micFrames == 0 {
            recLog.error("recording stopped with 0 microphone frames (source=\(self.source.rawValue, privacy: .public)) — dead/muted input device, wrong input selected, or failed format conversion")
        }
        // SCK delivers buffers even for silence, so a session with an app-audio
        // leg that saw none never received app audio at all. In meeting mode
        // `writes` is driven by the mic clock and looks normal regardless.
        if (source == .systemAudio || source == .meeting) && systemBuffersSinceStart == 0 && !isFakeForTesting {
            recLog.error("recording stopped with 0 system-audio buffers (source=\(self.source.rawValue, privacy: .public)) — the app-audio leg delivered nothing")
        }
        let url = fileURL
        audioFile = nil
        fileURL = nil
        startTime = nil
        pausedAt = nil
        totalPaused = 0
        meters.elapsed = 0
        isFakeForTesting = false
        resetLiveSourceState()
        state = .idle
        return url
    }

    /// Tear down any active capture without trying to flush a final WAV.
    /// Used by the AppDelegate at terminate time so we hand the user's mic
    /// and screen-recording grants back to macOS instead of leaving them
    /// pinned by a half-running session.
    func cancelAll() async {
        guard state != .idle else { return }
        isCancellingAll = true
        // Same fence as `stop()`: invalidate first, then let any in-flight
        // leg bring-up finish so it cannot resurrect capture after teardown.
        liveConfigGeneration += 1
        liveChangeCancellation?.cancel()
        let inFlight = liveChangeTask
        if let inFlight { _ = await inFlight.value }
        await mic.stop()
        await system.stop()
        micTask?.cancel(); micTask = nil
        systemTask?.cancel(); systemTask = nil
        timerTask?.cancel(); timerTask = nil
        audioFile = nil
        fileURL = nil
        startTime = nil
        pausedAt = nil
        totalPaused = 0
        meters.elapsed = 0
        isFakeForTesting = false
        pendingSystem.removeAll(keepingCapacity: false)
        state = .idle
        resetLiveSourceState()
    }

    // MARK: - Live source reconfiguration

    // Test-only permission seam, nil on every production caller. The race
    // below owns ONLY the permission request, never an engine start. A late
    // OS reply cannot reach capture after Stop/Quit wins cancellation.
    var liveMicrophonePermissionOverride: (@MainActor () async -> Bool)?

    private enum LivePermissionResult: Sendable, Equatable { case granted, denied, cancelled, timedOut }

    private static func liveMicrophonePermission(
        cancellation: CaptureStartCancellation,
        operation: @escaping @MainActor () async -> Bool
    ) async -> LivePermissionResult {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (LivePermissionResult) -> Void = { result in
                let first = claimed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: result) }
            }
            Task { @MainActor in
                let granted = await operation()
                finish(granted ? .granted : .denied)
            }
            Task { @MainActor in
                for _ in 0..<300 {
                    if claimed.withLock({ $0 }) { return }
                    if cancellation.isCancelled { finish(.cancelled); return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                finish(.timedOut)
            }
        }
    }


    /// Serialized mic / app-audio inclusion change for the CURRENT recording.
    ///
    /// Reuses the existing per-leg permission/start paths and never creates a
    /// second whole-session start/stop cycle: the WAV identity/URL, elapsed
    /// clock, live pipeline and initial `source` metadata are untouched.
    /// Turning a leg on opens it when it was never opened or stopped; a
    /// previously opened leg that was muted stays running for clock/watchdog
    /// purposes and is simply re-included.
    ///
    /// Both off reuses `pause()` but records that the pause came from the
    /// source state, so re-enabling one resumes it. A manual pause is never
    /// auto-resumed. Calling this while manually paused may still bring up the
    /// requested leg, but the existing paused gate keeps every sample out.
    ///
    /// Failures roll back only the leg that failed: the recording and the
    /// other leg keep running, the failed leg is marked unavailable, and the
    /// per-leg error is thrown for the controller to map onto its existing
    /// permission/error surfaces.
    ///
    /// Returns whether an accepted inclusion change was applied (`false` for
    /// a no-op request). Throws `LiveSourceChangeError` for rejection/failure.
    @discardableResult
    func setLiveSources(wantMic: Bool, wantSystem: Bool) async throws -> Bool {
        guard state == .recording || state == .paused, !isCancellingAll else {
            throw LiveSourceChangeError.noActiveRecording
        }
        guard !isChangingLiveSources else {
            throw LiveSourceChangeError.changeInFlight
        }

        let micWasIncluded = micIncluded
        let systemWasIncluded = systemIncluded
        guard wantMic != micWasIncluded || wantSystem != systemWasIncluded else {
            return false
        }

        let generation = liveConfigGeneration + 1
        liveConfigGeneration = generation
        liveChangeCancellation?.cancel()
        let cancellation = CaptureStartCancellation()
        liveChangeCancellation = cancellation
        isChangingLiveSources = true
        defer {
            // A stop/cancel bumps the generation and resets this itself; only
            // the still-current attempt may clear the in-flight state.
            if generation == liveConfigGeneration {
                isChangingLiveSources = false
                micStarting = false
                systemStarting = false
                liveChangeCancellation = nil
                liveChangeTask = nil
            }
        }

        // The routing changed at this boundary. Anything parked was produced
        // under the old routing and must not be replayed after the change.
        pendingSystem.removeAll(keepingCapacity: false)

        if !wantMic && micIncluded {
            micIncluded = false
            meters.micLevel = 0
        }
        if !wantSystem && systemIncluded {
            systemIncluded = false
            meters.systemLevel = 0
        }

        let needsMicBringUp = wantMic && (!micLegOpened || (!isFakeForTesting && !mic.isRunning))
        let needsSystemBringUp = wantSystem && (!systemLegOpened || (!isFakeForTesting && !system.isRunning))
        if needsMicBringUp {
            micStarting = true
            micUnavailable = false
            meters.micLevel = 0
        }
        if needsSystemBringUp {
            systemStarting = true
            systemUnavailable = false
            meters.systemLevel = 0
        }

        // One task for the awaited bring-up so `stop()`/`cancelAll()` can
        // invalidate the token and wait for a late completion before they
        // tear down. The task never throws: a failed leg is recorded in the
        // outcome so the other leg can still succeed.
        let task: Task<LegBringUpOutcome, Never> = Task { @MainActor [weak self] in
            guard let self else {
                var gone = LegBringUpOutcome()
                gone.cancelled = true
                return gone
            }
            var outcome = LegBringUpOutcome()

            if needsMicBringUp {
                let permission = await Self.liveMicrophonePermission(cancellation: cancellation) {
                    if let override = self.liveMicrophonePermissionOverride { return await override() }
                    return await self.mic.requestAccess()
                }
                if permission == .cancelled {
                    outcome.cancelled = true
                } else if permission == .timedOut {
                    outcome.micError = .microphoneUnavailable("Microphone permission did not complete. Try turning the microphone on again.")
                } else if permission == .denied {
                    outcome.micError = .microphonePermissionDenied
                } else if cancellation.isCancelled
                            || self.liveConfigGeneration != generation
                            || !self.isLiveSourceActive {
                    outcome.cancelled = true
                } else {
                    do {
                        try await self.mic.start(cancellation: cancellation)
                        if cancellation.isCancelled
                            || self.liveConfigGeneration != generation
                            || !self.isLiveSourceActive {
                            outcome.cancelled = true
                        } else {
                            outcome.micStarted = true
                        }
                    } catch is CaptureStartCancellation.Cancelled {
                        outcome.cancelled = true
                    } catch {
                        outcome.micError = .microphoneUnavailable(error.localizedDescription)
                    }
                }
            }

            if needsSystemBringUp && !outcome.cancelled {
                if cancellation.isCancelled
                    || self.liveConfigGeneration != generation
                    || !self.isLiveSourceActive {
                    outcome.cancelled = true
                } else {
                    do {
                        try await self.system.start(cancellation: cancellation)
                        if cancellation.isCancelled
                            || self.liveConfigGeneration != generation
                            || !self.isLiveSourceActive {
                            outcome.cancelled = true
                        } else {
                            outcome.systemStarted = true
                        }
                    } catch SystemAudioRecorder.CaptureError.permissionDenied {
                        outcome.systemError = .systemAudioPermissionDenied
                    } catch is CaptureStartCancellation.Cancelled {
                        outcome.cancelled = true
                    } catch {
                        outcome.systemError = .systemAudioUnavailable(error.localizedDescription)
                    }
                }
            }

            return outcome
        }
        liveChangeTask = task

        let outcome = await task.value

        // Stop/cancel wins if it invalidated us while the bring-up awaited.
        // `stop()`/`cancelAll()` are waiting on this task before their own
        // teardown, so whatever engine opened is their responsibility.
        guard !outcome.cancelled,
              !cancellation.isCancelled,
              liveConfigGeneration == generation,
              isLiveSourceActive else {
            throw LiveSourceChangeError.cancelled
        }

        if needsMicBringUp {
            if outcome.micStarted {
                installMicConsumer()
                micLegOpened = true
                micIncluded = true
                micUnavailable = false
            } else {
                micIncluded = false
                micUnavailable = outcome.micError != nil
                meters.micLevel = 0
            }
            micStarting = false
        } else if wantMic && !micIncluded {
            // Previously opened (muted) leg: no bring-up needed.
            micIncluded = true
            micUnavailable = false
        }

        if needsSystemBringUp {
            if outcome.systemStarted {
                installSystemConsumer()
                systemLegOpened = true
                systemIncluded = true
                systemUnavailable = false
            } else {
                systemIncluded = false
                systemUnavailable = outcome.systemError != nil
                meters.systemLevel = 0
            }
            systemStarting = false
        } else if wantSystem && !systemIncluded {
            systemIncluded = true
            systemUnavailable = false
        }
        if !wantMic { micStarting = false }
        if !wantSystem { systemStarting = false }

        if micIncluded != micWasIncluded || systemIncluded != systemWasIncluded {
            legsChangedDuringRecording = true
        }
        // A previously-refused resume is no longer refused once a source is
        // back in the accepted set, even if the session stays manually paused.
        if micIncluded || systemIncluded {
            lastResumeRefusal = nil
        }

        if !micIncluded && !systemIncluded {
            // Both off: reuse the existing pause, but mark it so re-enabling
            // a source resumes ONLY this pause.
            if state == .recording {
                autoPausedBySourceState = true
                await performPause()
            }
        } else if state == .paused && autoPausedBySourceState {
            _ = resume()
        }

        if let micError = outcome.micError {
            throw micError
        }
        if let systemError = outcome.systemError {
            throw systemError
        }
        return true
    }

    /// The active recording states a source change can run in. `.stopping` /
    /// `.idle` mean Stop won the race.
    private var isLiveSourceActive: Bool {
        state == .recording || state == .paused
    }

    private func installMicConsumer() {
        micTask?.cancel()
        let epoch = captureEpoch
        micTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in self.mic.audioStream {
                if Task.isCancelled { break }
                // A later recording owns a different capture epoch; this
                // consumer must not feed it stale buffers. Source toggles in
                // the SAME recording keep the epoch, and inclusion booleans
                // gate their samples instead.
                guard self.captureEpoch == epoch else { break }
                await self.consumeMic(buffer)
            }
        }
    }

    private func installSystemConsumer() {
        systemTask?.cancel()
        let epoch = captureEpoch
        systemTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in self.system.audioStream {
                if Task.isCancelled { break }
                guard self.captureEpoch == epoch else { break }
                await self.consumeSystem(buffer)
            }
        }
    }

    // MARK: - Mixing

    /// Internal rather than private so `RecordingSessionMetersTests` and the
    /// source-toggle tests can push buffers through the REAL mic path of a
    /// fake session and count who publishes; nothing in the app calls it from
    /// outside this file.
    func consumeMic(_ buffer: AVAudioPCMBuffer) async {
        // Paused: discard the buffer entirely so nothing reaches the WAV or
        // the live transcriber. The engine keeps running; we just drop its
        // output until `resume()`.
        guard state == .recording else { return }
        let samples = AudioConvert.samples(from: buffer)

        if !micIncluded {
            // Muted / clock-only mic. Its real samples never reach the meter,
            // the live feed or the WAV. An already-open mic still paces app
            // audio parked by `consumeSystem`, exactly like the meeting clock
            // — but muted spans drain at FULL system scale (never averaged
            // against a muted zero, which would halve the app audio).
            meters.micLevel = 0
            guard micLegOpened, systemIncluded else { return }
            await drainPendingSystemOnMutedMicClock(frames: samples.count)
            return
        }

        // Assign directly instead of hopping through `MainActor.run`: the
        // whole class is already `@MainActor`, so the hop bought nothing and
        // cost a suspension point — one a `pause()` could land inside, which
        // would leave the meter lit at a live-looking level for the rest of
        // the pause with nothing still running to clear it.
        meters.micLevel = AudioMeter.level(from: buffer)
        if !systemIncluded {
            // Mic-only: the live feed and the saved file are both just the
            // mic, so drive the live transcriber here and write directly.
            if let onLive = onLiveSamples { onLive(samples[0..<samples.count]) }
            await write(samples)
            return
        }
        // Both legs included: the mic is the master clock. Each mic chunk
        // pulls an equal span of system audio out of `pendingSystem`
        // (silence where the app wasn't playing) and mixes the two, then
        // drives BOTH the saved file and the live transcriber with the
        // result. Driving the mix off the mic's steady 16kHz cadence — rather
        // than the old min(pendingMic, pendingSystem) pairing — means the
        // live feed can't starve when the system leg goes quiet, and the
        // app-audio side reaches the live pane instead of only the on-disk
        // WAV.
        let mixed = mixWithBufferedSystem(mic: samples)
        if let onLive = onLiveSamples { onLive(mixed[0..<mixed.count]) }
        await write(mixed)
    }

    /// Drain app audio against a muted-but-still-open mic's cadence. The mic
    /// samples themselves are excluded; the app span is written at FULL
    /// system scale. Where the app had nothing buffered for part of the span
    /// the remainder is digital silence, which keeps the WAV duration paced by
    /// the mic clock and never substitutes the muted mic audio.
    private func drainPendingSystemOnMutedMicClock(frames: Int) async {
        guard frames > 0 else { return }
        let take = min(frames, pendingSystem.count)
        var span: [Float]
        if take > 0 {
            span = Array(pendingSystem.prefix(take))
            pendingSystem.removeFirst(take)
        } else {
            span = []
        }
        if span.count < frames {
            span.append(contentsOf: [Float](repeating: 0, count: frames - span.count))
        }
        guard !span.isEmpty else { return }
        if let onLive = onLiveSamples { onLive(span[0..<span.count]) }
        await write(span)
    }

    /// Internal like `consumeMic` so tests can drive the real system path
    /// (`deliverForTesting` pushes through the real SCK-shaped stream; this
    /// method is the routing under test). Nothing in the app calls it from
    /// outside this file.
    func consumeSystem(_ buffer: AVAudioPCMBuffer) async {
        // Paused: drop system audio too (both the inline app-only write and
        // the mic-clock jitter-buffer append) so the paused span is absent
        // from the recording.
        guard state == .recording else { return }
        systemBuffersSinceStart += 1
        let samples = AudioConvert.samples(from: buffer)

        if !systemIncluded {
            // Muted app audio: exclude its samples from the meter, live feed
            // and WAV. A straggler queued before the change lands here too,
            // which is why no pre-mute tail can be replayed.
            meters.systemLevel = 0
            return
        }

        // Direct assignment for the same reason as `consumeMic` — see there.
        meters.systemLevel = AudioMeter.level(from: buffer)

        if micLegOpened {
            // A mic clock exists (included, or open-but-muted). Park the
            // system audio for it to consume in `consumeMic`. Bound the
            // backlog so a stalled clock can't grow it without limit. The cap
            // is generous (~30s), so an SCK burst at session start or slow
            // clock skew just delays app audio until the clock catches up —
            // it isn't dropped.
            pendingSystem.append(contentsOf: samples)
            if pendingSystem.count > maxPendingSystem {
                // Hitting the cap means the mic clock has stalled outright
                // (display sleep/wake, input device yanked) while
                // ScreenCaptureKit kept delivering. The old behavior
                // discarded the oldest span, which cost a real user ~58
                // seconds of the other side of a meeting after a display wake
                // (2,883 consecutive 320-sample drops in one diagnostic
                // bundle). The clock isn't producing anything during a stall,
                // so nothing is being written — flush the overflow straight to
                // the WAV and the live feed instead (system-only, full scale,
                // exactly what `flushPendingSystemTail` does at stop). When the
                // clock resumes, mixing continues from the ≤30s still buffered.
                let overflowCount = pendingSystem.count - maxPendingSystem
                let overflow = Array(pendingSystem.prefix(overflowCount))
                pendingSystem.removeFirst(overflowCount)
                overflowFlushesSinceStart += 1
                if overflowFlushesSinceStart == 1 || overflowFlushesSinceStart % 100 == 0 {
                    recLog.error("system jitter buffer overflow #\(self.overflowFlushesSinceStart, privacy: .public) — mic clock stalled; flushing \(overflow.count, privacy: .public) samples to the WAV instead of dropping")
                }
                if let onLive = onLiveSamples { onLive(overflow[0..<overflow.count]) }
                await write(overflow)
            }
            return
        }

        // App-only: no mic clock exists (the mic is off and was never
        // opened), so ScreenCaptureKit is the clock. Write at full scale.
        if let onLive = onLiveSamples { onLive(samples[0..<samples.count]) }
        await write(samples)
    }

    /// Mix one mic chunk with the head of the buffered system audio and
    /// consume the system samples used. Where both legs overlap they're
    /// averaged (×0.5, so a simultaneously-loud mic + app can't clip); where
    /// no system audio is buffered the mic is kept at FULL scale (never
    /// halved). Drives both the saved WAV and the live transcriber with the
    /// same result.
    private func mixWithBufferedSystem(mic: [Float]) -> [Float] {
        let n = mic.count
        let take = min(n, pendingSystem.count)
        var mixed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i < take {
                // Both legs present → average so a simultaneous loud mic + app
                // can't clip past ±1.0.
                mixed[i] = (mic[i] + pendingSystem[i]) * 0.5
            } else {
                // No app audio buffered for this span → keep the mic at FULL
                // scale. Averaging here would silently halve the user's own
                // voice whenever the app is quiet, making a meeting capture
                // quieter than a plain voice memo of the same mic input.
                mixed[i] = mic[i]
            }
        }
        if take > 0 { pendingSystem.removeFirst(take) }
        return mixed
    }

    /// Flush any app audio still buffered when the mic clock stops (dual
    /// capture, or mic-muted app-only under an already-open mic clock). The
    /// clock is already stopped by the time `stop()`/`pause()` calls this, so
    /// the trailing span is app-only and goes out at full scale (the same way
    /// mic-only spans are written full scale in `mixWithBufferedSystem`), so
    /// the last bit of app audio isn't lost.
    private func flushPendingSystemTail() async {
        guard !pendingSystem.isEmpty else { return }
        let tail = pendingSystem
        pendingSystem.removeAll(keepingCapacity: false)
        if let onLive = onLiveSamples { onLive(tail[0..<tail.count]) }
        await write(tail)
    }

    private(set) var writesSinceStart: Int = 0

    /// System-audio buffers consumed this session. Unlike `writesSinceStart`
    /// this tells whether the app-audio leg delivered anything in meeting
    /// mode too.
    private(set) var systemBuffersSinceStart: Int = 0

    private func write(_ samples: [Float]) async {
        guard let file = audioFile, !samples.isEmpty else { return }
        writesSinceStart += 1
        if writesSinceStart <= 3 || writesSinceStart % 50 == 0 {
            let hasOnLive = onLiveSamples != nil
            recLog.log("write #\(self.writesSinceStart) samples=\(samples.count) hasOnLiveCb=\(hasOnLive, privacy: .public)")
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        do {
            try file.write(from: buffer)
        } catch {
            // The file being written lives in the recordings directory, which
            // is the folder the user chose in Settings → Storage, and Cocoa
            // quotes both the file and its containing folder in
            // `localizedDescription`. Domain + code stay public — a disk-full
            // versus a revoked-permission versus a vanished-volume write
            // failure is exactly what this line exists to tell apart, and
            // neither names a path. (Issue #213, CWE-532.)
            let ns = error as NSError
            recLog.error("""
                audio file write error \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
        }
        // The live-transcription feed is fired by the routing site, never
        // here: `consumeMic` handles mic-only, dual and muted-mic clock spans;
        // `consumeSystem` handles the inline app-only span; the two tail
        // flushes handle their own. Keeping it out of `write` means the feed
        // stays correct when the routing changes mid-recording.
    }
}

/// The high-frequency readouts of a `RecordingSession`: the elapsed clock and
/// the mic / system level meters.
///
/// A separate object so that the session itself only publishes on state
/// transitions. Anything that wants the live numbers observes THIS object —
/// and it should be a small leaf view (`RecordingElapsedLabel`,
/// `RecordingChip`), because whatever observes it re-renders at audio-buffer
/// cadence. Nothing at the `App` level may hold it as a `@StateObject`; see
/// `RecordingSession.meters` for the storm that caused.
///
/// Only `RecordingSession` writes these (`fileprivate(set)`): the values are
/// derived from its capture pipeline and its state machine, and letting a
/// view or controller poke them would decouple the meter from the audio it
/// claims to describe.
@MainActor
final class RecordingMeters: ObservableObject {
    @Published fileprivate(set) var elapsed: TimeInterval = 0
    @Published fileprivate(set) var micLevel: Float = 0
    @Published fileprivate(set) var systemLevel: Float = 0
}
