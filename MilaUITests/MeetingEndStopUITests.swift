import XCTest

/// Native preference and countdown coverage using the existing isolated,
/// synthetic meeting harness. No microphone or personal recording is opened.
final class MeetingEndStopUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", label, label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-clean-store", "--ui-test-meeting-auto", "--ui-test-reset-meeting-auto"]
        app.launch()
        XCTAssertTrue(element(app, "meetingTest.start").waitForExistence(timeout: 20))
        element(app, "meetingTest.ask").click()
        return app
    }

    private func enableStopSetting(_ app: XCUIApplication) {
        element(app, "sidebar.settings.link").click()
        let meetings = element(app, "settings.section.meetings")
        XCTAssertTrue(meetings.waitForExistence(timeout: 10))
        meetings.click()
        let toggle = element(app, "meetings.stopWhenMeetingEnds")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "The setting must start off in the reset test suite")
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "1")
        let settings = app.windows.containing(.any, identifier: "meetings.stopWhenMeetingEnds").firstMatch
        XCTAssertTrue(settings.exists)
        let attachment = XCTAttachment(screenshot: settings.screenshot())
        attachment.name = "meeting-end-stop-opt-in"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Use the ordinary Settings close action; the main fixture window stays open.
        app.typeKey("w", modifierFlags: .command)
    }

    private func startFromAsk(_ app: XCUIApplication) {
        element(app, "meetingTest.start").click()
        let start = element(app, "meetingPrompt.primary")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        waitForLabel(element(app, "meetingTest.state"), "Recording")
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 0")
    }

    private func assertStillRecordingPastCountdown(_ app: XCUIApplication) {
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Idle' OR value == 'Idle'"),
            object: element(app, "meetingTest.state"))
        stopped.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 11), .completed)
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 0")
    }

    func test_opt_in_persists_and_stops_an_Ask_started_recording_after_countdown() {
        let app = launch()
        defer { app.terminate() }
        enableStopSetting(app)
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset-meeting-auto" }
        app.launch()
        XCTAssertTrue(element(app, "meetingTest.start").waitForExistence(timeout: 20))
        startFromAsk(app)
        element(app, "meetingTest.end").click()
        XCTAssertTrue(element(app, "meetingStopPrompt.primary").waitForExistence(timeout: 5))
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 0")
        waitForLabel(element(app, "meetingTest.state"), "Idle")
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 1")
    }

    func test_keep_recording_cancels_the_opt_in_stop() {
        let app = launch()
        defer { app.terminate() }
        enableStopSetting(app)
        startFromAsk(app)
        element(app, "meetingTest.end").click()
        let keep = element(app, "meetingStopPrompt.dismiss")
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()
        assertStillRecordingPastCountdown(app)
    }

    func test_default_off_keeps_an_Ask_started_recording_running() {
        let app = launch()
        defer { app.terminate() }
        startFromAsk(app)
        element(app, "meetingTest.end").click()
        XCTAssertTrue(element(app, "meetingStopPrompt.primary").waitForExistence(timeout: 5))
        assertStillRecordingPastCountdown(app)
    }
}
