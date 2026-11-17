import XCTest
@testable import Mila

@MainActor
final class MenuBarControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var state: FakeState!
    private var controller: MenuBarController!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "MenuBarControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        state = FakeState()
        controller = MenuBarController(settingsDefaults: defaults)
        controller.configure(runtime: state.runtime)
    }

    override func tearDown() async throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    func test_start_reads_exactly_the_home_source_defaults() async {
        let first = expectation(description: "start 1")
        state.onStart = { first.fulfill() }
        controller.performRecord(stopRequested: controller.canStop)
        await fulfillment(of: [first], timeout: 2)
        await waitForActionToFinish()
        XCTAssertEqual(state.startCalls.count, 1)
        XCTAssertEqual(state.startCalls[0].microphone, true)
        XCTAssertEqual(state.startCalls[0].appAudio, true)

        defaults.set(false, forKey: MenuBarSourceSettings.microphoneKey)
        defaults.set(true, forKey: MenuBarSourceSettings.appAudioKey)
        controller.refresh()

        let second = expectation(description: "start 2")
        state.onStart = { second.fulfill() }
        controller.performRecord(stopRequested: controller.canStop)
        await fulfillment(of: [second], timeout: 2)
        await waitForActionToFinish()
        XCTAssertEqual(state.startCalls.count, 2)
        XCTAssertEqual(state.startCalls[1].microphone, false)
        XCTAssertEqual(state.startCalls[1].appAudio, true)
    }

    func test_refused_start_reveals_a_hidden_main_window() async {
        state.startBegan = false
        let started = expectation(description: "start finished")
        state.onStart = { started.fulfill() }
        controller.performRecord(stopRequested: controller.canStop)
        await fulfillment(of: [started], timeout: 2)
        await waitForActionToFinish()
        XCTAssertEqual(state.revealCalls, 1,
                       "A start that never claimed the job must not disappear silently")
    }

    func test_permission_failure_reveals_the_existing_recovery_ui() async {
        let started = expectation(description: "start finished")
        state.onStart = {
            self.state.blocking = true
            started.fulfill()
        }
        controller.performRecord(stopRequested: controller.canStop)
        await fulfillment(of: [started], timeout: 2)
        await waitForActionToFinish()
        XCTAssertEqual(state.revealCalls, 1)
        XCTAssertTrue(state.blocking, "The controller must not reset the existing error")
    }

    func test_stop_routes_for_every_capture_source_and_paused() async {
        let jobs: [QuickActionsController.ActiveJob] = [
            .recordingMic,
            .recording(withSystemAudio: false),
            .recording(withSystemAudio: true),
            .recordingApp(processID: nil, includeMic: false),
            .recordingApp(processID: pid_t(3), includeMic: true)
        ]
        for (index, job) in jobs.enumerated() {
            state.input.activeJob = job
            state.input.sessionState = index.isMultiple(of: 2) ? .recording : .paused
            controller.refresh()
            XCTAssertTrue(controller.canStop, "\(job) must offer Stop")

            let stopped = expectation(description: "stop \(job)")
            state.onStop = { stopped.fulfill() }
            controller.performRecord(stopRequested: controller.canStop)
            await fulfillment(of: [stopped], timeout: 2)
            await waitForActionToFinish()
            XCTAssertEqual(state.stopCalls, index + 1)
            XCTAssertTrue(state.startCalls.isEmpty,
                          "A capture state must never route to Start")
        }
    }

    func test_stale_stop_does_not_start_after_external_stop() async {
        state.input.activeJob = .recording(withSystemAudio: true)
        state.input.sessionState = .recording
        controller.refresh()
        let displayedStop = controller.canStop
        state.input.activeJob = .none
        state.input.sessionState = .idle
        controller.refresh()
        controller.performRecord(stopRequested: displayedStop)
        await Task.yield()
        XCTAssertTrue(state.startCalls.isEmpty)
        XCTAssertEqual(state.stopCalls, 0)
    }

    func test_stale_start_does_not_stop_after_external_start() async {
        let displayedStop = controller.canStop
        state.input.activeJob = .recordingApp(processID: nil, includeMic: false)
        state.input.sessionState = .recording
        controller.refresh()
        controller.performRecord(stopRequested: displayedStop)
        await Task.yield()
        XCTAssertTrue(state.startCalls.isEmpty)
        XCTAssertEqual(state.stopCalls, 0)
    }

    func test_queued_start_revalidates_before_shared_toggle() async {
        controller.performRecord(stopRequested: false)
        state.input.activeJob = .recording(withSystemAudio: true)
        state.input.sessionState = .recording
        await waitForActionToFinish()
        XCTAssertTrue(state.startCalls.isEmpty)
        XCTAssertEqual(state.stopCalls, 0)
    }

    func test_queued_stop_revalidates_after_external_stop() async {
        state.input.activeJob = .recording(withSystemAudio: true)
        state.input.sessionState = .recording
        controller.refresh()
        controller.performRecord(stopRequested: true)
        state.input.activeJob = .none
        state.input.sessionState = .idle
        await waitForActionToFinish()
        XCTAssertTrue(state.startCalls.isEmpty)
        XCTAssertEqual(state.stopCalls, 0)
    }

    func test_repeated_stop_while_stopping_is_disabled() {
        state.input.activeJob = .recording(withSystemAudio: true)
        state.input.isStoppingRecording = true
        controller.refresh()
        XCTAssertFalse(controller.canStop)
        XCTAssertFalse(controller.canStart)
    }

    func test_hidden_blocking_state_is_revealed_once_per_transition() {
        state.blocking = true
        controller.refresh()
        XCTAssertEqual(state.revealCalls, 1)

        controller.refresh()
        XCTAssertEqual(state.revealCalls, 1, "A persistent error must not keep re-revealing")

        state.blocking = false
        controller.refresh()
        state.blocking = true
        controller.refresh()
        XCTAssertEqual(state.revealCalls, 2)
    }

    func test_both_sources_off_is_explained_and_blocks_start() {
        defaults.set(false, forKey: MenuBarSourceSettings.microphoneKey)
        defaults.set(false, forKey: MenuBarSourceSettings.appAudioKey)
        controller.refresh()
        XCTAssertEqual(controller.status, .chooseSource)
        XCTAssertFalse(controller.canStart)
        XCTAssertNotNil(controller.sourceCaption)
    }

    func test_preparing_and_importing_disable_start_while_open_stays_available() async {
        state.input.isPreparingModel = true
        controller.refresh()
        XCTAssertEqual(controller.status, .preparing)
        XCTAssertFalse(controller.canStart)

        state.input.isPreparingModel = false
        state.input.isImporting = true
        controller.refresh()
        XCTAssertEqual(controller.status, .importing)
        XCTAssertFalse(controller.canStart)

        // Open Mila has no state gate; a missing resident window reports
        // false so the menu can fall back to openWindow(id:).
        state.restoreSucceeds = false
        XCTAssertFalse(controller.openMainWindow())
        state.restoreSucceeds = true
        XCTAssertTrue(controller.openMainWindow())
        XCTAssertEqual(state.restoreCalls, 2)
    }

    private func waitForActionToFinish() async {
        for _ in 0..<100 {
            if !controller.isPerformingAction { return }
            await Task.yield()
        }
        XCTFail("Menu-bar action did not finish")
    }

    func test_record_title_tracks_the_single_action() {
        XCTAssertEqual(controller.recordTitle, "Start Recording")
        state.input.activeJob = .recording(withSystemAudio: true)
        state.input.sessionState = .paused
        controller.refresh()
        XCTAssertEqual(controller.recordTitle, "Stop Recording")
    }
}

@MainActor
private final class FakeState {
    var input = MenuBarStatusInput()
    var blocking = false
    var startBegan = true
    var restoreSucceeds = true
    var startCalls: [(microphone: Bool, appAudio: Bool)] = []
    var stopCalls = 0
    var revealCalls = 0
    var restoreCalls = 0
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    var runtime: MenuBarController.Runtime {
        MenuBarController.Runtime(
            input: { self.input },
            start: { microphone, appAudio in
                self.startCalls.append((microphone, appAudio))
                self.onStart?()
            },
            stop: {
                self.stopCalls += 1
                self.onStop?()
            },
            startBegan: { self.startBegan },
            blockingState: { self.blocking },
            revealIfHidden: { self.revealCalls += 1 },
            restoreMainWindow: {
                self.restoreCalls += 1
                return self.restoreSucceeds
            }
        )
    }
}
