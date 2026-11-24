import XCTest
import AVFoundation
import os
import TranscriptionCore
@testable import Mila

/// Backend proof for live microphone / app-audio toggles on `RecordingSession`.
///
/// Everything here goes through the REAL `consumeMic` / `consumeSystem` /
/// mixer / `onLiveSamples` / `AVAudioFile.write` paths. The fake start opens
/// the same WAV writer the production `start` uses only when `writeFile:` is
/// true, so saved-sample assertions are about bytes on disk, never no-op
/// counters. No hardware capture, ScreenCaptureKit stream, or permission
/// prompt is used: lazy leg bring-up goes through the existing
/// `bringUpOverride` seams and a test-owned temp WAV.
@MainActor
final class RecordingSessionSourceToggleTests: XCTestCase {
    private static let frames = 1_600

    // MARK: - Mic -> dual -> mic amplitudes

    func test_mic_to_dual_to_mic_writes_exact_amplitudes() async throws {
        let session = RecordingSession()
        let url = tempURL("mic-dual-mic")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)

        let live = LiveBuffer()
        session.onLiveSamples = { live.append($0) }
        let mic = try constantBuffer(0.8)
        let app = try constantBuffer(0.4)

        // Mic only: full scale.
        await session.consumeMic(mic)
        XCTAssertGreaterThan(session.micLevel, 0)

        // Both legs: the existing mic-master mix averages overlapping spans.
        try await session.setLiveSources(wantMic: true, wantSystem: true)
        XCTAssertTrue(session.systemIncluded)
        await session.consumeSystem(app)      // parked for the mic clock
        await session.consumeMic(mic)         // drained and mixed

        // App muted again: the mic returns to full scale, no app tail replay.
        try await session.setLiveSources(wantMic: true, wantSystem: false)
        XCTAssertEqual(session.systemLiveState, .muted)
        XCTAssertEqual(session.systemLevel, 0)
        await session.consumeSystem(app)      // dropped
        await session.consumeMic(mic)

        _ = await session.stop()
        let wav = try loadWAV(url)
        XCTAssertEqual(wav.count, Self.frames * 3)
        assertConstant(wav[0..<Self.frames], 0.8, "mic-only span must stay full scale")
        assertConstant(wav[Self.frames..<(Self.frames * 2)], 0.6,
                       "dual span must keep the existing (mic + app) * 0.5 gain")
        assertConstant(wav[(Self.frames * 2)..<(Self.frames * 3)], 0.8,
                       "mic-only after muting app must be full scale")

        XCTAssertEqual(live.samples.count, Self.frames * 3)
        assertConstant(live.samples[0..<Self.frames], 0.8, "live mic-only")
        assertConstant(live.samples[Self.frames..<(Self.frames * 2)], 0.6, "live dual mix")
        assertConstant(live.samples[(Self.frames * 2)..<(Self.frames * 3)], 0.8,
                       "live mic-only after app mute")
    }

    // MARK: - Mic-muted app-only cadence

    func test_muted_mic_app_only_drains_at_full_system_scale() async throws {
        let session = RecordingSession()
        let url = tempURL("app-only")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)

        let live = LiveBuffer()
        session.onLiveSamples = { live.append($0) }
        let mic = try constantBuffer(0.8)
        let app = try constantBuffer(0.4)

        try await session.setLiveSources(wantMic: false, wantSystem: true)
        XCTAssertEqual(session.state, .recording)
        XCTAssertFalse(session.micIncluded)
        XCTAssertTrue(session.systemIncluded)
        XCTAssertEqual(session.micLiveState, .muted,
                       "an open-but-excluded mic is muted, not hardware-off")
        XCTAssertEqual(session.micLevel, 0, "muting zeroes the meter immediately")

        await session.consumeSystem(app)
        await session.consumeMic(mic)
        await session.consumeSystem(app)
        await session.consumeMic(mic)

        _ = await session.stop()
        let wav = try loadWAV(url)
        XCTAssertEqual(wav.count, Self.frames * 2)
        // FULL app scale: a muted mic must not contribute a zero that the
        // dual-source mixer would average down to 0.2.
        assertConstant(wav[0..<Self.frames], 0.4, "app audio must stay at full scale")
        assertConstant(wav[Self.frames..<(Self.frames * 2)], 0.4, "app audio must stay at full scale")
        XCTAssertEqual(live.samples.count, Self.frames * 2)
        assertConstant(live.samples[0..<Self.frames], 0.4, "live app-only full scale")
        assertConstant(live.samples[Self.frames..<(Self.frames * 2)], 0.4, "live app-only full scale")
        // None of the muted mic's 0.8 ever reached the WAV or the live feed.
        XCTAssertFalse(wav.contains { abs($0 - 0.8) < 0.01 })
        XCTAssertEqual(session.source, .microphone,
                       "source stays the recording's initial metadata")
    }

    func test_muted_mic_with_no_app_audio_writes_silence_not_mic() async throws {
        let session = RecordingSession()
        let url = tempURL("app-only-silence")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)

        let live = LiveBuffer()
        session.onLiveSamples = { live.append($0) }
        let mic = try constantBuffer(0.8)

        try await session.setLiveSources(wantMic: false, wantSystem: true)
        await session.consumeMic(mic)   // cadence with no app audio parked

        _ = await session.stop()
        let wav = try loadWAV(url)
        XCTAssertEqual(wav.count, Self.frames,
                       "the mic clock still paces a span for duration")
        assertConstant(wav[0..<Self.frames], 0, "absent app audio is digital silence")
        assertConstant(live.samples[0..<Self.frames], 0, "no muted mic sample is published")
        XCTAssertEqual(session.micLevel, 0)
    }

    // MARK: - Muting excludes the disabled leg, no tail replay

    func test_muting_system_excludes_samples_zeroes_meter_and_never_replays_pending_tail() async throws {
        let session = RecordingSession()
        let url = tempURL("system-mute")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)

        let live = LiveBuffer()
        session.onLiveSamples = { live.append($0) }
        let mic = try constantBuffer(0.8)
        let app = try constantBuffer(0.4)

        try await session.setLiveSources(wantMic: true, wantSystem: true)
        await session.consumeSystem(app)
        await session.consumeMic(mic)
        let writesBeforeMute = session.writesSinceStart
        live.reset()

        // App audio is parked, then the app leg is muted: the boundary must
        // clear that pre-change tail rather than replay it later.
        await session.consumeSystem(app)
        try await session.setLiveSources(wantMic: true, wantSystem: false)
        XCTAssertEqual(session.systemLevel, 0)
        XCTAssertEqual(session.systemLiveState, .muted)

        await session.consumeSystem(app)
        XCTAssertEqual(session.writesSinceStart, writesBeforeMute,
                       "a muted app leg must not write")
        XCTAssertTrue(live.samples.isEmpty, "a muted app leg must not reach the live feed")

        await session.consumeMic(mic)
        _ = await session.stop()
        let wav = try loadWAV(url)
        XCTAssertEqual(wav.count, Self.frames * 2)
        assertConstant(wav[0..<Self.frames], 0.6, "pre-mute dual span")
        assertConstant(wav[Self.frames..<(Self.frames * 2)], 0.8,
                       "post-mute mic-only span, with no replayed app tail")
    }

    // MARK: - Both-off auto pause vs a manual pause

    func test_both_off_auto_pauses_and_refuses_resume_until_a_source_returns() async throws {
        let session = RecordingSession()
        let url = tempURL("both-off")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)

        let live = LiveBuffer()
        session.onLiveSamples = { live.append($0) }
        try await session.setLiveSources(wantMic: true, wantSystem: true)

        try await session.setLiveSources(wantMic: false, wantSystem: false)
        XCTAssertEqual(session.state, .paused)
        XCTAssertTrue(session.autoPausedBySourceState)
        XCTAssertTrue(session.legsChangedDuringRecording)
        XCTAssertEqual(session.micLevel, 0)
        XCTAssertEqual(session.systemLevel, 0)

        let writesPaused = session.writesSinceStart
        XCTAssertFalse(session.resume(), "resume with both sources excluded must refuse")
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.lastResumeRefusal, .bothSourcesExcluded)
        XCTAssertFalse(session.lastResumeRefusal?.message.isEmpty ?? true)

        await session.consumeMic(try constantBuffer(0.8))
        await session.consumeSystem(try constantBuffer(0.4))
        XCTAssertEqual(session.writesSinceStart, writesPaused,
                       "the paused gate still drops both legs")
        XCTAssertTrue(live.samples.isEmpty)

        // Re-enabling a source resumes the AUTO pause only.
        try await session.setLiveSources(wantMic: true, wantSystem: false)
        XCTAssertEqual(session.state, .recording)
        XCTAssertFalse(session.autoPausedBySourceState)
        XCTAssertNil(session.lastResumeRefusal)
        _ = await session.stop()
    }

    func test_manual_pause_is_never_auto_resumed_by_a_source_toggle() async throws {
        let session = RecordingSession()
        let url = tempURL("manual-pause")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)

        let live = LiveBuffer()
        session.onLiveSamples = { live.append($0) }
        await session.pause()
        XCTAssertEqual(session.state, .paused)
        XCTAssertFalse(session.autoPausedBySourceState)

        // Enabling a leg while manually paused may bring it up, but the
        // paused gate stays closed and the session must not resume.
        try await session.setLiveSources(wantMic: true, wantSystem: true)
        XCTAssertEqual(session.state, .paused)
        XCTAssertTrue(session.systemIncluded)
        XCTAssertFalse(session.autoPausedBySourceState)

        let writesPaused = session.writesSinceStart
        await session.consumeMic(try constantBuffer(0.8))
        await session.consumeSystem(try constantBuffer(0.4))
        XCTAssertEqual(session.writesSinceStart, writesPaused)
        XCTAssertTrue(live.samples.isEmpty)

        // Disabling and re-enabling the mic must not turn it into an
        // auto-resume either.
        try await session.setLiveSources(wantMic: false, wantSystem: true)
        try await session.setLiveSources(wantMic: true, wantSystem: true)
        XCTAssertEqual(session.state, .paused,
                       "a source toggle must never resume a manual pause")
        XCTAssertTrue(session.resume())
        XCTAssertEqual(session.state, .recording)
        _ = await session.stop()
    }

    // MARK: - Per-leg failure keeps the recording and the other leg

    func test_system_enable_failure_rolls_back_only_that_leg_and_recording_continues() async throws {
        let session = RecordingSession()
        let url = tempURL("system-failure")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {
            throw SystemAudioRecorder.CaptureError.permissionDenied
        }
        await session.startFakeForTesting(outputURL: url, writeFile: true)
        let mic = try constantBuffer(0.8)

        await assertLiveSourceError(.systemAudioPermissionDenied) {
            try await session.setLiveSources(wantMic: true, wantSystem: true)
        }
        XCTAssertEqual(session.state, .recording)
        XCTAssertTrue(session.micIncluded)
        XCTAssertFalse(session.systemIncluded)
        XCTAssertTrue(session.systemUnavailable)
        XCTAssertEqual(session.systemLiveState, .unavailable)

        let writesBefore = session.writesSinceStart
        await session.consumeMic(mic)
        XCTAssertGreaterThan(session.writesSinceStart, writesBefore,
                             "the recording and the mic leg keep running after the failure")

        // A retry is a new request: it clears Unavailable and can succeed.
        session.system.bringUpOverride = {}
        try await session.setLiveSources(wantMic: true, wantSystem: true)
        XCTAssertTrue(session.systemIncluded)
        XCTAssertFalse(session.systemUnavailable)
        _ = await session.stop()
    }

    func test_mic_enable_failure_on_an_app_recording_keeps_the_system_leg() async throws {
        let session = RecordingSession()
        let url = tempURL("mic-failure")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        try await session.start(source: .systemAudio, outputURL: url)
        session.mic.bringUpOverride = { throw LegStartFailure() }

        do {
            _ = try await session.setLiveSources(wantMic: true, wantSystem: true)
            XCTFail("the failing mic bring-up should have thrown")
        } catch let error as RecordingSession.LiveSourceChangeError {
            guard case .microphoneUnavailable(let detail) = error else {
                XCTFail("expected microphoneUnavailable, got \(error)")
                return
            }
            XCTAssertFalse(detail.isEmpty, "the failure carries a readable cause")
        }

        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.source, .systemAudio)
        XCTAssertFalse(session.micIncluded)
        XCTAssertTrue(session.systemIncluded)
        XCTAssertTrue(session.micUnavailable)

        let writesBefore = session.writesSinceStart
        await session.consumeSystem(try constantBuffer(0.4))
        XCTAssertGreaterThan(session.writesSinceStart, writesBefore,
                             "the app leg still writes after the mic bring-up failed")
        _ = await session.stop()
    }

    // MARK: - Stop / cancel vs a held enable

    func test_stop_during_a_held_enable_never_resurrects_and_the_next_start_is_clean() async throws {
        let session = RecordingSession()
        let url = tempURL("held-stop")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        try await session.start(source: .systemAudio, outputURL: url)

        let entered = OSAllocatedUnfairLock(initialState: false)
        let release = OSAllocatedUnfairLock(initialState: false)
        session.mic.bringUpOverride = {
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        let change = Task { try await session.setLiveSources(wantMic: true, wantSystem: true) }
        await waitUntil { entered.withLock { $0 } }
        XCTAssertTrue(entered.withLock { $0 }, "the mic bring-up never started")
        XCTAssertTrue(session.isChangingLiveSources)

        // A second toggle while in flight is rejected, not queued.
        await assertLiveSourceError(.changeInFlight) {
            try await session.setLiveSources(wantMic: true, wantSystem: true)
        }

        let stopTask = Task { await session.stop() }
        await waitUntil { session.state == .stopping }
        XCTAssertEqual(session.state, .stopping)
        release.withLock { $0 = true }
        _ = try? await change.value
        let out = await stopTask.value

        XCTAssertEqual(out, url)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.mic.isRunning)
        XCTAssertFalse(session.system.isRunning)
        XCTAssertFalse(session.micUnavailable,
                       "a stop-cancelled enable is not a permission/engine failure")
        XCTAssertFalse(session.isChangingLiveSources)
        XCTAssertFalse(session.legsChangedDuringRecording,
                       "teardown resets the changed-legs marker")

        // The next recording starts clean; the stale enable did not touch it.
        let nextURL = tempURL("held-stop-next")
        defer { try? FileManager.default.removeItem(at: nextURL) }
        await session.startFakeForTesting(outputURL: nextURL, writeFile: true)
        XCTAssertEqual(session.state, .recording)
        XCTAssertTrue(session.micIncluded)
        let writesBefore = session.writesSinceStart
        await session.consumeMic(try constantBuffer(0.8))
        XCTAssertGreaterThan(session.writesSinceStart, writesBefore,
                             "the next recording captures normally")
        _ = await session.stop()
    }

    func test_cancel_all_during_a_held_enable_never_resurrects_and_the_next_start_is_clean() async throws {
        let session = RecordingSession()
        let url = tempURL("held-cancel")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        try await session.start(source: .systemAudio, outputURL: url)

        let entered = OSAllocatedUnfairLock(initialState: false)
        let release = OSAllocatedUnfairLock(initialState: false)
        session.mic.bringUpOverride = {
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        let change = Task { try await session.setLiveSources(wantMic: true, wantSystem: true) }
        await waitUntil { entered.withLock { $0 } }
        XCTAssertTrue(entered.withLock { $0 })

        let generationBefore = session.liveConfigGeneration
        let cancelTask = Task { await session.cancelAll() }
        await waitUntil { session.liveConfigGeneration != generationBefore }
        XCTAssertNotEqual(session.liveConfigGeneration, generationBefore)
        release.withLock { $0 = true }
        _ = try? await change.value
        await cancelTask.value

        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.mic.isRunning)
        XCTAssertFalse(session.system.isRunning)
        XCTAssertFalse(session.isChangingLiveSources)
        XCTAssertFalse(session.micIncluded)
        XCTAssertFalse(session.systemIncluded)

        let nextURL = tempURL("held-cancel-next")
        defer { try? FileManager.default.removeItem(at: nextURL) }
        await session.startFakeForTesting(outputURL: nextURL, writeFile: true)
        XCTAssertEqual(session.state, .recording)
        let writesBefore = session.writesSinceStart
        await session.consumeMic(try constantBuffer(0.8))
        XCTAssertGreaterThan(session.writesSinceStart, writesBefore)
        _ = await session.stop()
    }

    // MARK: - Dead legs and a pending OS permission prompt

    func test_reenabling_stopped_legs_restarts_capture_instead_of_reporting_false_listening() async throws {
        let session = RecordingSession()
        let url = tempURL("dead-legs")
        defer { try? FileManager.default.removeItem(at: url) }
        var micStarts = 0
        var systemStarts = 0
        session.mic.bringUpOverride = { micStarts += 1 }
        session.system.bringUpOverride = { systemStarts += 1 }
        try await session.start(source: .meeting, outputURL: url)
        XCTAssertEqual(micStarts, 1)
        XCTAssertEqual(systemStarts, 1)

        await session.mic.stop()
        XCTAssertEqual(session.micLiveState, .unavailable)
        try await session.setLiveSources(wantMic: false, wantSystem: true)
        try await session.setLiveSources(wantMic: true, wantSystem: true)
        XCTAssertEqual(micStarts, 2)
        XCTAssertTrue(session.mic.isRunning)
        XCTAssertEqual(session.micLiveState, .listening)

        await session.system.stop()
        XCTAssertEqual(session.systemLiveState, .unavailable)
        try await session.setLiveSources(wantMic: true, wantSystem: false)
        try await session.setLiveSources(wantMic: true, wantSystem: true)
        XCTAssertEqual(systemStarts, 2)
        XCTAssertTrue(session.system.isRunning)
        XCTAssertEqual(session.systemLiveState, .listening)
        _ = await session.stop()
    }

    func test_stop_settles_without_permission_reply_and_late_grant_cannot_start_capture() async throws {
        try await assertPendingPermissionSettles(useCancelAll: false)
    }

    func test_quit_cancellation_settles_without_permission_reply_and_late_grant_cannot_start_capture() async throws {
        try await assertPendingPermissionSettles(useCancelAll: true)
    }

    private func assertPendingPermissionSettles(useCancelAll: Bool) async throws {
        let session = RecordingSession()
        let url = tempURL("pending-permission")
        let nextURL = tempURL("after-permission")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: nextURL)
        }
        session.system.bringUpOverride = {}
        try await session.start(source: .systemAudio, outputURL: url)
        let entered = OSAllocatedUnfairLock(initialState: false)
        let released = OSAllocatedUnfairLock(initialState: false)
        let replied = OSAllocatedUnfairLock(initialState: false)
        defer { released.withLock { $0 = true } }
        var micStarts = 0
        session.mic.bringUpOverride = { micStarts += 1 }
        session.liveMicrophonePermissionOverride = {
            entered.withLock { $0 = true }
            while !released.withLock({ $0 }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            replied.withLock { $0 = true }
            return true
        }
        let change = Task { try await session.setLiveSources(wantMic: true, wantSystem: true) }
        await waitUntil { entered.withLock { $0 } }
        XCTAssertTrue(entered.withLock { $0 })
        let settled = OSAllocatedUnfairLock(initialState: false)
        let stopTask = Task {
            if useCancelAll { await session.cancelAll() }
            else { _ = await session.stop() }
            settled.withLock { $0 = true }
        }
        await waitUntil(timeout: 2) { settled.withLock { $0 } }
        let settledBeforeReply = settled.withLock { $0 }
        XCTAssertTrue(settledBeforeReply, "Stop and Quit must settle while the permission reply is still held")
        // Release on failure so a regression fails an assertion rather than hanging.
        if !settledBeforeReply { released.withLock { $0 = true } }
        await stopTask.value
        _ = try? await change.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(micStarts, 0)

        await session.startFakeForTesting(outputURL: nextURL, writeFile: true)
        let epoch = session.captureEpoch
        released.withLock { $0 = true }
        await waitUntil { replied.withLock { $0 } }
        XCTAssertTrue(replied.withLock { $0 })
        // Let the permission-only task return through the losing race branch.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(micStarts, 0, "the late OS grant must never start an engine")
        XCTAssertEqual(session.captureEpoch, epoch)
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.fileURL, nextURL)
        _ = await session.stop()
    }

    // MARK: - Identity, generation and teardown reset

    func test_live_toggles_keep_initial_metadata_and_reset_state_at_teardown() async throws {
        let session = RecordingSession()
        let url = tempURL("identity")
        defer { try? FileManager.default.removeItem(at: url) }
        session.system.bringUpOverride = {}
        await session.startFakeForTesting(outputURL: url, writeFile: true)
        let startedAt = session.startedAt
        let epoch = session.captureEpoch

        try await session.setLiveSources(wantMic: false, wantSystem: true)
        XCTAssertEqual(session.source, .microphone, "source stays the initial metadata")
        XCTAssertEqual(session.fileURL, url, "the WAV identity/URL is never recreated")
        XCTAssertEqual(session.startedAt, startedAt, "the wall clock start is unchanged")
        XCTAssertEqual(session.captureEpoch, epoch,
                       "a live toggle is not a new recording")
        XCTAssertTrue(session.legsChangedDuringRecording)

        _ = await session.stop()
        XCTAssertFalse(session.legsChangedDuringRecording)
        XCTAssertFalse(session.autoPausedBySourceState)
        XCTAssertNil(session.lastResumeRefusal)
        XCTAssertFalse(session.micIncluded)
        XCTAssertFalse(session.systemIncluded)
        XCTAssertFalse(session.micUnavailable)
        XCTAssertFalse(session.systemUnavailable)

        let nextURL = tempURL("identity-next")
        defer { try? FileManager.default.removeItem(at: nextURL) }
        await session.startFakeForTesting(outputURL: nextURL)
        XCTAssertFalse(session.legsChangedDuringRecording)
        XCTAssertEqual(session.source, .microphone)
        _ = await session.stop()
    }

    // MARK: - Helpers

    private final class LiveBuffer {
        private(set) var samples: [Float] = []
        func reset() { samples.removeAll() }
        func append(_ slice: ArraySlice<Float>) { samples.append(contentsOf: slice) }
    }

    private struct LegStartFailure: Error {}

    private func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("source-toggle-\(label)-\(UUID().uuidString).wav")
    }

    private func constantBuffer(_ value: Float, frames: Int = RecordingSessionSourceToggleTests.frames) throws -> AVAudioPCMBuffer {
        let format = WhisperAudioFormat.pcmFloat32
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<frames {
            channel[i] = value
        }
        return buffer
    }

    private func loadWAV(_ url: URL) throws -> [Float] {
        try AudioConvert.loadAsWhisperSamples(url: url)
    }

    private func assertConstant(_ samples: ArraySlice<Float>, _ expected: Float, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(samples.isEmpty, message, file: file, line: line)
        let maxDelta = samples.map { abs($0 - expected) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(maxDelta, 1e-4,
                                 "\(message) (expected \(expected), max delta \(maxDelta))",
                                 file: file, line: line)
    }

    private func assertLiveSourceError(_ expected: RecordingSession.LiveSourceChangeError,
                                       _ body: @MainActor () async throws -> Bool,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as RecordingSession.LiveSourceChangeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
