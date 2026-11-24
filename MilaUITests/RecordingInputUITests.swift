import XCTest

/// Native fixture slice for the live recording input controls and meters.
///
/// Every test launches with a UUID-owned clean store, a UUID-owned defaults
/// suite and a validated `Mila-UITest-<UUID>` 0700 root. The app-side
/// `RecordingInputUITestHarness` starts the real fake-recording controller
/// path and pushes synthetic buffers through the real microphone / system
/// routing. No microphone, ScreenCaptureKit stream, TCC prompt, live model,
/// LLM or remote backend is opened; every screenshot is of the app window.
@MainActor
final class RecordingInputUITests: XCTestCase {
    private var root: URL!
    private var suiteID: UUID!

    private static let denyMarker = "Mila-UITest-recording-inputs-deny"
    private static let holdMarker = "Mila-UITest-recording-inputs-hold"
    private static let holdEnteredMarker = "Mila-UITest-recording-inputs-hold-entered"
    private static let releaseMarker = "Mila-UITest-recording-inputs-release"

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("Mila-UITest-\(UUID().uuidString)", isDirectory: true)
        suiteID = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: "Mila.StorageUITests.\(suiteID.uuidString)")
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func launch(_ scenario: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MILA_UI_TEST_CLEAN_ROOT"] = root.path
        app.launchArguments = [
            "--uitests",
            "--ui-test-clean-store",
            "--ui-test-storage-suite=\(suiteID.uuidString)",
            "--ui-test-recording-inputs=\(scenario)"
        ] + extraArguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func meter(_ app: XCUIApplication, labeled label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ", "))
            .firstMatch
    }

    private func toggle(_ app: XCUIApplication, _ leg: String) -> XCUIElement {
        element(app, "recording.inputs.\(leg).toggle")
    }

    private func state(_ app: XCUIApplication, _ leg: String) -> XCUIElement {
        element(app, "recording.inputs.\(leg).state")
    }

    private func visibleText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: "\n")
    }

    private func waitForInputs(_ app: XCUIApplication) {
        let leaf = element(app, "recording.inputs")
        XCTAssertTrue(leaf.waitForExistence(timeout: 30),
                      "The actual recording surface must show the shared input leaf")
    }

    private func waitForState(_ app: XCUIApplication,
                              _ leg: String,
                              contains fragment: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let stateElement = state(app, leg)
        XCTAssertTrue(stateElement.waitForExistence(timeout: 15),
                      "\(leg) state label missing", file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                   fragment, fragment),
            object: stateElement)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "\(leg) state must read \(fragment); observed \(visibleText(stateElement))",
                       file: file, line: line)
    }

    private func waitForContains(_ element: XCUIElement,
                                 _ fragment: String,
                                 timeout: TimeInterval = 10,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                   fragment, fragment),
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected \(fragment); observed \(visibleText(element))",
                       file: file, line: line)
    }

    private func waitForVisibleText(_ app: XCUIApplication,
                                    contains fragment: String,
                                    timeout: TimeInterval = 10,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Expected visible text containing \(fragment)",
                      file: file, line: line)
    }

    private func waitForNonExistence(_ element: XCUIElement,
                                     timeout: TimeInterval = 10,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Element must disappear", file: file, line: line)
    }

    private func assertToggle(_ element: XCUIElement,
                              on expected: Bool,
                              _ message: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                if let number = element.value as? NSNumber { return number.boolValue == expected }
                let value = ((element.value as? String) ?? "").lowercased()
                return expected ? (value == "1" || value == "on")
                                : (value == "0" || value == "off")
            },
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
                       message, file: file, line: line)
    }

    private func meterPercent(_ element: XCUIElement) -> Int? {
        Self.meterPercent(value: element.value as? String, label: element.label)
    }

    private static func meterPercent(value: String?, label: String) -> Int? {
        // The real meter publishes the same reading as both AXValue and
        // part of AXLabel because macOS omits AXValue on some Other nodes.
        for text in [value ?? "", label.components(separatedBy: ", ").last ?? ""] {
            if text == "off" { return 0 }
            guard text.hasSuffix(" percent"),
                  let percent = Int(text.dropLast(" percent".count)) else { continue }
            return percent
        }
        return nil
    }

    private func waitForMeter(_ element: XCUIElement,
                              nonzero: Bool,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10),
                      "Meter element missing", file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                guard let percent = Self.meterPercent(value: element.value as? String,
                                                     label: element.label) else { return false }
                return nonzero ? percent > 0 : percent == 0
            },
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       nonzero ? "Meter must show a live nonzero level"
                               : "Meter must show no stale live level",
                       file: file, line: line)
    }

    private func waitForWAVFile(timeout: TimeInterval = 15) -> Bool {
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                for name in names where name.hasSuffix(".wav") {
                    let url = directory.appendingPathComponent(name)
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > 0 {
                        return true
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    /// The controller maps a live app-audio permission failure onto the
    /// existing system permission alert as well as the inline message. Read
    /// that alert and cancel it so the inline, persistent Unavailable state
    /// can be inspected; never open System Settings.
    private func dismissPermissionAlertIfPresent(_ app: XCUIApplication) {
        let alert = app.dialogs.firstMatch
        guard alert.waitForExistence(timeout: 8) else { return }
        let cancel = alert.buttons["Cancel"]
        guard cancel.waitForExistence(timeout: 5) else { return }
        cancel.click()
        waitForNonExistence(alert)
    }

    private func markerURL(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }

    private func createMarker(_ name: String) {
        _ = FileManager.default.createFile(atPath: markerURL(name).path, contents: Data())
    }

    private func removeMarker(_ name: String) {
        try? FileManager.default.removeItem(at: markerURL(name))
    }

    private func waitForMarker(_ name: String, timeout: TimeInterval = 10) -> Bool {
        let url = markerURL(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// Never capture the desktop: only the app window that owns the rendered
    /// recording surface.
    private func appWindowScreenshot(_ app: XCUIApplication, named name: String) {
        let window = app.windows.firstMatch
        let target = window.exists ? window : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Cases

    func test_both_included_meters_are_labelled_and_show_differing_levels() {
        let app = launch("both-included")
        defer { app.terminate() }
        waitForInputs(app)
        XCTAssertTrue(element(app, "home.record.hero").waitForExistence(timeout: 10),
                      "The live controls must be mounted on the actual Home surface")
        XCTAssertFalse(element(app, "home.record.microphone.toggle").exists,
                       "The idle preference pair must be absent while recording")
        XCTAssertFalse(element(app, "home.record.appaudio.toggle").exists,
                       "The idle preference pair must be absent while recording")

        let micToggle = toggle(app, "microphone")
        let appToggle = toggle(app, "appAudio")
        XCTAssertTrue(micToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(appToggle.waitForExistence(timeout: 15))
        assertToggle(micToggle, on: true, "Microphone must start included")
        assertToggle(appToggle, on: true, "App audio must be included for this fixture")
        waitForState(app, "microphone", contains: "Included")
        waitForState(app, "appAudio", contains: "Included")

        let micMeter = meter(app, labeled: "Microphone level")
        let appMeter = meter(app, labeled: "App audio level")
        XCTAssertTrue(micMeter.waitForExistence(timeout: 10),
                      "The microphone meter must have its own label")
        XCTAssertTrue(appMeter.waitForExistence(timeout: 10),
                      "The app-audio meter must have its own label")
        waitForMeter(micMeter, nonzero: true)
        waitForMeter(appMeter, nonzero: true)

        let micLevel = meterPercent(micMeter) ?? -1
        let appLevel = meterPercent(appMeter) ?? -1
        XCTAssertGreaterThan(micLevel, 0)
        XCTAssertGreaterThan(appLevel, 0)
        XCTAssertNotEqual(micLevel, appLevel,
                          "Distinct synthetic amplitudes must read as different levels")
        XCTAssertTrue(waitForWAVFile(),
                      "The real session writer must create the test-owned WAV file")
        appWindowScreenshot(app, named: "Both included distinct microphone and app meters")
    }

    func test_space_toggles_microphone_accepted_state_and_zeroes_its_meter() {
        let app = launch("microphone-only")
        defer { app.terminate() }
        waitForInputs(app)

        let micToggle = toggle(app, "microphone")
        XCTAssertTrue(micToggle.waitForExistence(timeout: 15))
        assertToggle(micToggle, on: true, "Microphone must start included")
        waitForState(app, "microphone", contains: "Included")
        let micMeter = meter(app, labeled: "Microphone level")
        waitForMeter(micMeter, nonzero: true)

        // Click focuses the native switch; the following literal Space is the
        // keyboard activation that must go through the same accepted path.
        micToggle.click()
        waitForState(app, "microphone", contains: "Muted")
        assertToggle(micToggle, on: false, "Muting must be the accepted state")
        waitForMeter(micMeter, nonzero: false)

        app.typeKey(" ", modifierFlags: [])
        waitForState(app, "microphone", contains: "Included")
        assertToggle(micToggle, on: true, "Space must be accepted as re-enabling the microphone")
        waitForMeter(micMeter, nonzero: true)
        appWindowScreenshot(app, named: "Microphone re-enabled with native Space")
    }

    func test_both_sources_off_pauses_with_reason_hints_and_keeps_stop_available() {
        let app = launch("microphone-only")
        defer { app.terminate() }
        waitForInputs(app)

        let micToggle = toggle(app, "microphone")
        let appToggle = toggle(app, "appAudio")
        XCTAssertTrue(micToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(appToggle.waitForExistence(timeout: 15))
        assertToggle(micToggle, on: true, "Microphone must start included")
        assertToggle(appToggle, on: false, "App audio must start excluded")
        waitForState(app, "microphone", contains: "Included")

        micToggle.click()
        waitForState(app, "microphone", contains: "Muted")

        let reason = element(app, "recording.inputs.pauseReason")
        XCTAssertTrue(reason.waitForExistence(timeout: 10))
        waitForContains(reason, "Paused: both sources muted")
        let hint = element(app, "recording.inputs.resumeHint")
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        waitForContains(hint, "Turn on a source to resume.")

        let stop = element(app, "home.record.hero")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(stop.isEnabled, "Stop must stay available while both sources are off")
        XCTAssertTrue(stop.isHittable, "Stop must be reachable while both sources are off")
        let blockedResume = element(app, "recording.resumeBlocked")
        XCTAssertTrue(blockedResume.waitForExistence(timeout: 10))
        XCTAssertFalse(blockedResume.isEnabled,
                       "Resume must be visibly refused while both sources are off")
        appWindowScreenshot(app, named: "Both sources off auto-paused with Stop available")

        micToggle.click()
        waitForState(app, "microphone", contains: "Included")
        waitForNonExistence(reason)
        XCTAssertTrue(stop.isEnabled, "Stop must remain available after the automatic resume")
        assertToggle(micToggle, on: true, "Re-enabling a source must be the accepted state")
    }

    func test_failed_app_audio_enable_rolls_back_then_a_held_retry_starts() {
        let app = launch("microphone-only")
        var holdArmed = false
        defer {
            if holdArmed { createMarker(Self.releaseMarker) }
            app.terminate()
        }
        waitForInputs(app)

        let micToggle = toggle(app, "microphone")
        let appToggle = toggle(app, "appAudio")
        XCTAssertTrue(micToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(appToggle.waitForExistence(timeout: 15))
        assertToggle(micToggle, on: true, "Microphone must start included")
        assertToggle(appToggle, on: false, "App audio must start excluded")
        waitForState(app, "microphone", contains: "Included")
        let micMeter = meter(app, labeled: "Microphone level")
        waitForMeter(micMeter, nonzero: true)

        // Permission failure: the real SCK-shaped override throws the
        // recorder's own permission error.
        createMarker(Self.denyMarker)
        appToggle.click()
        dismissPermissionAlertIfPresent(app)
        waitForState(app, "appAudio", contains: "Unavailable")
        let error = element(app, "recording.inputs.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        waitForVisibleText(app, contains: "Screen & System Audio Recording permission is required")
        assertToggle(appToggle, on: false, "A failed enable must roll the switch back")
        waitForState(app, "microphone", contains: "Included")
        waitForMeter(micMeter, nonzero: true)
        appWindowScreenshot(app, named: "App audio permission failure rolled back")

        let dismiss = app.buttons["Dismiss input message"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.click()
        waitForNonExistence(error)
        waitForState(app, "appAudio", contains: "Unavailable")

        // Held retry: Starting… with the accepted-old switch position and
        // disabled transitions until the seam is released.
        removeMarker(Self.denyMarker)
        createMarker(Self.holdMarker)
        holdArmed = true
        appToggle.click()
        waitForState(app, "appAudio", contains: "Starting")
        XCTAssertTrue(waitForMarker(Self.holdEnteredMarker),
                      "The held bring-up must report that it is holding")
        XCTAssertFalse(appToggle.isEnabled,
                       "Switches must be disabled while a source change is in flight")
        assertToggle(appToggle, on: false,
                     "The requested leg must keep the accepted-old position while Starting")
        waitForState(app, "microphone", contains: "Included")
        waitForMeter(micMeter, nonzero: true)
        appWindowScreenshot(app, named: "App audio Starting with accepted old switch position")

        createMarker(Self.releaseMarker)
        holdArmed = false
        waitForState(app, "appAudio", contains: "Included")
        assertToggle(appToggle, on: true, "Releasing the held bring-up must accept app audio")
        XCTAssertTrue(appToggle.isEnabled)
        waitForMeter(meter(app, labeled: "App audio level"), nonzero: true)
    }

    func test_narrow_rtl_live_header_keeps_stop_and_pause_reachable() throws {
        let app = launch("live-rtl", extraArguments: ["--ui-test-rtl-live-hebrew"])
        defer { app.terminate() }

        let stop = element(app, "liveAI.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 30),
                      "The live recording header must expose Stop")
        let pause = element(app, "recording.pause")
        XCTAssertTrue(pause.waitForExistence(timeout: 15),
                      "The live recording header must expose Pause")
        waitForInputs(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "The main app window must exist")
        let before = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.999))
        let target = window.coordinate(withNormalizedOffset: CGVector(dx: -0.6, dy: -0.6))
        corner.press(forDuration: 0.3, thenDragTo: target)
        let after = window.frame
        appWindowScreenshot(app, named: "Narrow Hebrew RTL live header with input controls")

        if abs(after.width - before.width) < 2 && before.width > 1_100 {
            try XCTSkip("Corner drag did not resize the main window (\(before) -> \(after))")
        }
        XCTAssertLessThanOrEqual(after.width, 1_100,
                                 "The live header fixture must run at a narrow window width")
        XCTAssertTrue(window.frame.contains(stop.frame),
                      "Stop must stay inside the visible window at narrow width")
        XCTAssertTrue(window.frame.contains(pause.frame),
                      "Pause must stay inside the visible window at narrow width")
        XCTAssertTrue(stop.isHittable, "Stop must be reachable at narrow width in RTL")
        XCTAssertTrue(pause.isHittable, "Pause must be reachable at narrow width in RTL")
        let leaf = element(app, "recording.inputs")
        XCTAssertTrue(leaf.exists)
        XCTAssertTrue(window.frame.contains(leaf.frame),
                      "The shared input row must stay inside the visible narrow window")
    }
}
