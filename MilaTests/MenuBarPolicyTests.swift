import XCTest
@testable import Mila

final class MenuBarPolicyTests: XCTestCase {
    private func input(_ configure: (inout MenuBarStatusInput) -> Void = { _ in }) -> MenuBarStatusInput {
        var value = MenuBarStatusInput()
        configure(&value)
        return value
    }

    func test_idle_ready_and_both_sources_off() {
        XCTAssertEqual(MenuBarPolicy.status(for: input()), .ready)
        XCTAssertEqual(MenuBarPolicy.sourceCaption(for: input()),
                       "Start records the microphone and app audio.")

        let noSources = input {
            $0.microphoneEnabled = false
            $0.appAudioEnabled = false
        }
        XCTAssertEqual(MenuBarPolicy.status(for: noSources), .chooseSource)
        XCTAssertEqual(MenuBarPolicy.sourceCaption(for: noSources),
                       "Turn on Microphone or App audio in Open Mila to start.")
        XCTAssertFalse(MenuBarPolicy.canStart(noSources))
    }

    func test_source_caption_matches_the_enabled_source() {
        XCTAssertEqual(MenuBarPolicy.sourceCaption(for: input { $0.appAudioEnabled = false }),
                       "Start records the microphone.")
        XCTAssertEqual(MenuBarPolicy.sourceCaption(for: input { $0.microphoneEnabled = false }),
                       "Start records app audio.")
    }

    func test_stopping_outranks_every_other_state() {
        let stopping = input {
            $0.isStoppingRecording = true
            $0.activeJob = .recording(withSystemAudio: true)
            $0.sessionState = .stopping
            $0.isPreparingModel = true
            $0.isTranscriptionBusy = true
            $0.isImporting = true
            $0.microphoneEnabled = false
            $0.appAudioEnabled = false
        }
        XCTAssertEqual(MenuBarPolicy.status(for: stopping), .stopping)
        XCTAssertFalse(MenuBarPolicy.canStart(stopping))
        XCTAssertFalse(MenuBarPolicy.canStop(stopping))
    }

    func test_starting_outranks_preparation_processing_and_import() {
        let starting = input {
            $0.activeJob = .starting(.microphone)
            $0.isPreparingModel = true
            $0.isTranscriptionBusy = true
            $0.isImporting = true
        }
        XCTAssertEqual(MenuBarPolicy.status(for: starting), .starting)
        XCTAssertEqual(MenuBarPolicy.status(for: input { $0.isCaptureStartInFlight = true }),
                       .starting)
        XCTAssertFalse(MenuBarPolicy.canStart(starting))
        XCTAssertFalse(MenuBarPolicy.canStop(starting))
    }

    func test_active_capture_outranks_preparation_processing_and_import() {
        let recording = input {
            $0.activeJob = .recording(withSystemAudio: true)
            $0.sessionState = .recording
            $0.isPreparingModel = true
            $0.isTranscriptionBusy = true
            $0.isImporting = true
        }
        XCTAssertEqual(MenuBarPolicy.status(for: recording), .recording)
        XCTAssertTrue(MenuBarPolicy.canStop(recording))
        XCTAssertFalse(MenuBarPolicy.canStart(recording))
        XCTAssertNil(MenuBarPolicy.sourceCaption(for: recording))

        let paused = input {
            $0.activeJob = .recordingApp(processID: pid_t(42), includeMic: true)
            $0.sessionState = .paused
            $0.isPreparingModel = true
            $0.isTranscriptionBusy = true
        }
        XCTAssertEqual(MenuBarPolicy.status(for: paused), .paused)
        XCTAssertTrue(MenuBarPolicy.canStop(paused))
        XCTAssertNil(MenuBarPolicy.sourceCaption(for: paused))
    }

    func test_stop_is_available_for_every_capture_source() {
        let jobs: [QuickActionsController.ActiveJob] = [
            .recordingMic,
            .recording(withSystemAudio: false),
            .recording(withSystemAudio: true),
            .recordingApp(processID: nil, includeMic: false),
            .recordingApp(processID: pid_t(7), includeMic: true)
        ]
        for job in jobs {
            let running = input { $0.activeJob = job; $0.sessionState = .recording }
            XCTAssertTrue(MenuBarPolicy.canStop(running), "\(job) must offer Stop")
            XCTAssertEqual(MenuBarPolicy.status(for: running), .recording)

            let paused = input { $0.activeJob = job; $0.sessionState = .paused }
            XCTAssertTrue(MenuBarPolicy.canStop(paused), "\(job) paused must offer Stop")
            XCTAssertEqual(MenuBarPolicy.status(for: paused), .paused)
        }
    }

    func test_preparing_processing_and_importing_are_distinct_disabled_states() {
        let preparing = input {
            $0.isPreparingModel = true
            $0.isTranscriptionBusy = true
            $0.isImporting = true
        }
        XCTAssertEqual(MenuBarPolicy.status(for: preparing), .preparing)
        XCTAssertFalse(MenuBarPolicy.canStart(preparing))

        let processing = input { $0.isTranscriptionBusy = true }
        XCTAssertEqual(MenuBarPolicy.status(for: processing), .processing)
        XCTAssertTrue(MenuBarPolicy.canStart(processing),
                      "Transcription queue alone does not block a new recording")

        let importing = input { $0.isImporting = true }
        XCTAssertEqual(MenuBarPolicy.status(for: importing), .importing)
        XCTAssertFalse(MenuBarPolicy.canStart(importing))
    }

    func test_start_is_enabled_only_for_an_idle_controller_with_a_source() {
        XCTAssertTrue(MenuBarPolicy.canStart(input()))
        XCTAssertTrue(MenuBarPolicy.canStart(input { $0.appAudioEnabled = false }))
        XCTAssertTrue(MenuBarPolicy.canStart(input { $0.microphoneEnabled = false }))

        XCTAssertFalse(MenuBarPolicy.canStart(input { $0.activeJob = .starting(.microphone) }))
        XCTAssertFalse(MenuBarPolicy.canStart(input { $0.activeJob = .importingFile(URL(fileURLWithPath: "/tmp/a.wav")) }))
        XCTAssertFalse(MenuBarPolicy.canStart(input { $0.activeJob = .recording(withSystemAudio: false) }))
        XCTAssertFalse(MenuBarPolicy.canStart(input { $0.isStoppingRecording = true }))
        XCTAssertFalse(MenuBarPolicy.canStart(input { $0.isCaptureStartInFlight = true }))
        XCTAssertFalse(MenuBarPolicy.canStart(input { $0.isPreparingModel = true }))
    }

    func test_every_state_has_a_unique_shape_and_named_accessibility_text() {
        XCTAssertEqual(MenuBarStatus.allCases.count, 9)
        XCTAssertEqual(Set(MenuBarStatus.allCases.map(\.symbolName)).count,
                       MenuBarStatus.allCases.count,
                       "Each state needs its own shape, not a colour distinction")
        for state in MenuBarStatus.allCases {
            XCTAssertTrue(state.accessibilityLabel.hasPrefix("Mila — "))
            XCTAssertTrue(state.accessibilityLabel.contains(state.title))
            XCTAssertFalse(state.title.isEmpty)
        }
        XCTAssertEqual(MenuBarStatus.recording.accessibilityLabel, "Mila — Recording")
    }

    func test_first_close_copy_is_state_aware_and_never_claims_idle_recording() {
        XCTAssertEqual(MenuBarFirstCloseNotice.forStatus(.ready).title, "Mila keeps running")
        XCTAssertFalse(MenuBarFirstCloseNotice.forStatus(.ready).message.contains("recording will continue"))
        XCTAssertFalse(MenuBarFirstCloseNotice.forStatus(.chooseSource).message.contains("recording will continue"))

        XCTAssertTrue(MenuBarFirstCloseNotice.forStatus(.recording).message
            .contains("Your recording will continue while this window is closed."))
        XCTAssertTrue(MenuBarFirstCloseNotice.forStatus(.paused).message
            .contains("Your recording will stay paused."))
        for state in [MenuBarStatus.starting, .stopping, .preparing, .processing, .importing] {
            XCTAssertTrue(MenuBarFirstCloseNotice.forStatus(state).message
                .contains("Work in progress will continue."), "\(state) copy")
        }
    }
}
