import XCTest

/// Native menu-bar lifecycle checks in an isolated host. Recording tests use
/// the existing fake-recording seam (no microphone, no personal store, no
/// audio fixture) and only verify that the status item, menu bindings and
/// resident window survive. VoiceOver audio itself remains a hands-on limit.
final class MenuBarUITests: XCTestCase {
    private let menuBarSuitePrefix = "Mila.MenuBarUITests."
    private var suiteID: UUID!
    private var tempRoot: URL!
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        suiteID = UUID()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mila.MenuBarUITests.\(suiteID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let suiteID {
            UserDefaults().removePersistentDomain(forName: menuBarSuitePrefix + suiteID.uuidString)
        }
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    // MARK: - Idle window lifecycle

    func test_idle_close_and_reopen_keeps_one_resident_window_and_settings_close_is_normal() {
        acknowledgeNotice()
        let application = launch()
        defer { application.terminate() }

        waitForStatusLabel(application, containing: "Ready")
        let main = mainWindow(application)
        XCTAssertTrue(main.waitForExistence(timeout: 20))
        XCTAssertTrue(statusItem(application).label.contains("Mila"),
                      "The menu-bar item must expose its Mila accessibility name")
        XCTAssertTrue(statusItem(application).label.contains("Ready"))

        // Repeated X → Open cycles, with no first-close explanation.
        for _ in 0..<2 {
            closeMainWindow(application)
            assertNoBackgroundNotice(application)
            openMila(application)
            XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 10))
        }

        closeMainWindow(application)
        waitUntilGone(mainWindow(application))

        // Settings opens natively from the menu and closes normally, without
        // hiding the app or showing the background notice.
        openMenu(application)
        let settingsItem = menuItem(application, identifier: "menuBar.settings", title: "Settings…")
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5))
        XCTAssertTrue(settingsItem.isEnabled)
        settingsItem.click()

        let settings = application.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings must open from the menu")
        let close = settings.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "Settings must still close with its own X")

        XCTAssertFalse(mainWindow(application).exists,
                       "Closing Settings must not reveal the hidden main window")
        XCTAssertTrue(statusItem(application).exists, "The app stays alive in the menu bar")
        openMila(application)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 10))
    }

    func test_first_close_explains_background_running_once() {
        let application = launch()
        defer { application.terminate() }
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 20))

        closeMainWindow(application, expectNotice: true)
        let notice = backgroundNotice(application)
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "First close must explain that Mila keeps running")
        XCTAssertTrue(application.staticTexts["Mila keeps running"].exists)
        let message = noticeMessage(application, title: "Mila keeps running")
        XCTAssertTrue(message.contains("You can reopen Mila"),
                      "Idle copy must explain reopening/starting/quitting")
        XCTAssertFalse(message.contains("recording will continue"),
                       "Idle copy must never claim a recording is active")

        acknowledge(notice, application)
        waitUntilGone(notice)
        waitUntilGone(mainWindow(application))
        waitForDefaultsAcknowledgement()
        XCTAssertTrue(UserDefaults(suiteName: suiteName)!
            .bool(forKey: "menuBar.didExplainBackgroundRunning"))

        openMila(application)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 10))
        closeMainWindow(application)
        assertNoBackgroundNotice(application)
        waitUntilGone(mainWindow(application))
    }

    // MARK: - Active / paused capture

    func test_active_recording_survives_close_with_stop_reachable_and_quit_terminates() {
        let application = launch(fakeRecording: true)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 20))

        startFromMenu(application)
        waitForStatusLabel(application, containing: "Recording")

        closeMainWindow(application, expectNotice: true)
        let notice = backgroundNotice(application)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let message = noticeMessage(application, title: "Mila keeps running")
        XCTAssertTrue(message.contains("Your recording will continue while this window is closed."))
        waitForStatusLabel(application, containing: "Recording")
        acknowledge(notice, application)
        waitUntilGone(notice)
        waitUntilGone(mainWindow(application))

        waitForStatusLabel(application, containing: "Recording")
        // The SAME ContentView must still be alive behind the hidden window,
        // with the recording controls intact.
        openMila(application)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 10))
        XCTAssertTrue(element(application, "recording.pause").waitForExistence(timeout: 10),
                      "Reopening must preserve the live recording view")
        closeMainWindow(application)
        waitUntilGone(mainWindow(application))

        openMenu(application)
        let stop = menuItem(application, identifier: "menuBar.record", title: "Stop Recording")
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isEnabled, "Stop must stay reachable while the window is hidden")
        application.typeKey(.escape, modifierFlags: [])

        // Quit from the menu must terminate and must not show the notice.
        openMenu(application)
        let quit = menuItem(application, identifier: "menuBar.quit", title: "Quit Mila")
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.click()
        XCTAssertNotEqual(application.state, .runningForeground)
        waitUntilNotRunning(application)
        XCTAssertFalse(backgroundNotice(application).exists,
                       "Quit must not present the background-running notice")
    }

    func test_quit_from_menu_without_closing_terminates_without_notice() {
        let application = launch(fakeRecording: true)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 20))
        startFromMenu(application)
        waitForStatusLabel(application, containing: "Recording")

        openMenu(application)
        let quit = menuItem(application, identifier: "menuBar.quit", title: "Quit Mila")
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.click()
        waitUntilNotRunning(application)
        XCTAssertFalse(backgroundNotice(application).exists)
        XCTAssertFalse(UserDefaults(suiteName: suiteName)!
            .bool(forKey: "menuBar.didExplainBackgroundRunning"),
                       "Quit is not an acknowledgement of the first-close notice")
    }

    func test_paused_recording_survives_close_and_stays_stoppable() {
        let application = launch(fakeRecording: true)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 20))

        startFromMenu(application)
        waitForStatusLabel(application, containing: "Recording")
        openMila(application)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 10))

        let pause = element(application, "recording.pause")
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "Pause must be reachable in Home")
        pause.click()
        XCTAssertTrue(element(application, "recording.resume").waitForExistence(timeout: 5))
        waitForStatusLabel(application, containing: "Recording Paused")

        closeMainWindow(application, expectNotice: true)
        let notice = backgroundNotice(application)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let message = noticeMessage(application, title: "Mila keeps running")
        XCTAssertTrue(message.contains("Your recording will stay paused."))
        waitForStatusLabel(application, containing: "Recording Paused")
        acknowledge(notice, application)
        waitUntilGone(notice)
        waitUntilGone(mainWindow(application))

        waitForStatusLabel(application, containing: "Recording Paused")
        openMila(application)
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 10))
        XCTAssertTrue(element(application, "recording.resume").waitForExistence(timeout: 10),
                      "Reopening must preserve the paused recording view")
        closeMainWindow(application)
        waitUntilGone(mainWindow(application))

        openMenu(application)
        let stop = menuItem(application, identifier: "menuBar.record", title: "Stop Recording")
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isEnabled, "Paused capture must keep Stop available")
        application.typeKey(.escape, modifierFlags: [])

        openMenu(application)
        menuItem(application, identifier: "menuBar.quit", title: "Quit Mila").click()
        waitUntilNotRunning(application)
    }

    // MARK: - Blocked state, accessibility, keyboard

    func test_both_sources_off_shows_explanatory_status_and_disabled_start() {
        acknowledgeNotice()
        let application = launch(microphone: false, appAudio: false)
        defer { application.terminate() }
        XCTAssertTrue(mainWindow(application).waitForExistence(timeout: 20))

        waitForStatusLabel(application, containing: "Choose Audio Source")
        openMenu(application)
        let status = statusMenuText(application, expected: "Mila — Choose Audio Source")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(statusText(application, status).contains("Mila — Choose Audio Source"))

        let start = menuItem(application, identifier: "menuBar.record", title: "Start Recording")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled, "Start must be disabled with no source")
        XCTAssertTrue(menuItem(application, identifier: "menuBar.open", title: "Open Mila").isEnabled,
                      "Open Mila stays enabled in every state")
        XCTAssertTrue(menuItem(application, identifier: "menuBar.settings", title: "Settings…").isEnabled)
        XCTAssertTrue(menuItem(application, identifier: "menuBar.quit", title: "Quit Mila").isEnabled)

        // Genuine status-item menu keyboard navigation must dismiss cleanly
        // without starting a recording.
        application.typeKey(.downArrow, modifierFlags: [])
        application.typeKey(.upArrow, modifierFlags: [])
        application.typeKey(.escape, modifierFlags: [])
        waitUntilGone(menuItem(application, identifier: "menuBar.open", title: "Open Mila"))
        XCTAssertEqual(application.state, .runningForeground)
        waitForStatusLabel(application, containing: "Choose Audio Source")

        // Reopen with the keyboard and attempt Return. With Start disabled
        // this must never start a recording or quit; it may activate the
        // first enabled item (Open Mila) or leave the menu.
        openMenu(application)
        application.typeKey(.downArrow, modifierFlags: [])
        application.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(application.state, .runningForeground)
        waitForStatusLabel(application, containing: "Choose Audio Source")
    }

    // MARK: - Helpers

    private var suiteName: String { menuBarSuitePrefix + suiteID.uuidString }

    private func acknowledgeNotice() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "menuBar.didExplainBackgroundRunning")
        defaults.synchronize()
    }

    private func launch(microphone: Bool = true,
                        appAudio: Bool = true,
                        fakeRecording: Bool = false) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--uitests", "--ui-test-clean-store", "--ui-test-recording-lang-en",
            "--ui-test-menu-bar-suite=\(suiteID.uuidString)",
            "-home.record.microphone", microphone ? "YES" : "NO",
            "-home.record.withSystemAudio", appAudio ? "YES" : "NO",
            // Keep Home (with its Pause control) visible during the fake
            // recording instead of the live split pane.
            "-liveAI.transcribeWhileRecording", "YES",
            "-liveAI.backgroundMode", "YES",
            "-liveAI.enabled", "NO",
            "-liveAI.useVAD", "YES",
            "-liveAI.useNeuralVAD", "NO",
            "-diarization.enabled", "NO",
            "-speakers.voiceRecognition.enabled", "NO",
            "-llm.tool", "none",
            "-llm.name.enabled", "NO",
            "-llm.summary.enabled", "NO",
            "-llm.action.enabled", "NO",
            "-transcription.backend", "local",
        ]
        if fakeRecording {
            // The existing fake-start seam: no AVAudioEngine, no microphone.
            application.launchArguments.append("--ui-test-finalize-regression")
        }
        application.launchEnvironment["TMPDIR"] = tempRoot.path + "/"
        app = application
        application.launch()
        return application
    }

    private func mainWindow(_ application: XCUIApplication) -> XCUIElement {
        let titled = application.windows["Mila"]
        return titled.exists ? titled : application.windows.firstMatch
    }

    private func closeMainWindow(_ application: XCUIApplication, expectNotice: Bool = false) {
        let window = mainWindow(application)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let close = window.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        if !expectNotice {
            waitUntilGone(window)
        }
    }

    private func openMila(_ application: XCUIApplication) {
        openMenu(application)
        let open = menuItem(application, identifier: "menuBar.open", title: "Open Mila")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        open.click()
    }

    private func startFromMenu(_ application: XCUIApplication) {
        openMenu(application)
        let start = menuItem(application, identifier: "menuBar.record", title: "Start Recording")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.click()
    }

    private func openMenu(_ application: XCUIApplication) {
        let item = statusItem(application)
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        item.click()
        let open = menuItem(application, identifier: "menuBar.open", title: "Open Mila")
        XCTAssertTrue(open.waitForExistence(timeout: 5),
                      "Clicking the status item must open its native menu")
        // Capture only this app's menu/status item, never the whole desktop.
        let menu = application.menus.firstMatch
        let image = menu.exists ? menu.screenshot() : item.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "Mila menu bar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func statusItem(_ application: XCUIApplication) -> XCUIElement {
        application.statusItems.firstMatch
    }

    private func menuItem(_ application: XCUIApplication,
                          identifier: String,
                          title: String) -> XCUIElement {
        let byIdentifier = application.menuItems.matching(identifier: identifier).firstMatch
        if byIdentifier.exists { return byIdentifier }
        return application.menuItems[title]
    }

    private func statusMenuText(_ application: XCUIApplication, expected: String) -> XCUIElement {
        let byIdentifier = application.descendants(matching: .any)
            .matching(identifier: "menuBar.status").firstMatch
        if byIdentifier.exists { return byIdentifier }
        return application.descendants(matching: .any)[expected]
    }

    private func statusText(_ application: XCUIApplication, _ element: XCUIElement) -> String {
        let value = (element.value as? String) ?? ""
        return element.label + " " + value
    }

    private func backgroundNotice(_ application: XCUIApplication) -> XCUIElement {
        let sheet = application.sheets.firstMatch
        if sheet.exists { return sheet }
        return application.dialogs.firstMatch
    }

    private func noticeMessage(_ application: XCUIApplication, title: String) -> String {
        let texts = application.staticTexts
        var message = ""
        for index in 0..<texts.count {
            let text = texts.element(boundBy: index)
            if text.exists, text.label != title {
                message += text.label + " "
            }
        }
        return message
    }

    private func acknowledge(_ notice: XCUIElement, _ application: XCUIApplication) {
        let button = notice.buttons["Continue"]
        if button.exists {
            XCTAssertTrue(button.isEnabled)
            button.click()
        } else {
            let fallback = application.buttons["Continue"]
            XCTAssertTrue(fallback.waitForExistence(timeout: 5))
            fallback.click()
        }
    }

    private func assertNoBackgroundNotice(_ application: XCUIApplication) {
        XCTAssertFalse(application.sheets.firstMatch.exists,
                       "An acknowledged first close must not show the notice again")
        XCTAssertFalse(application.staticTexts["Mila keeps running"].exists)
    }

    private func waitForStatusLabel(_ application: XCUIApplication,
                                    containing state: String,
                                    timeout: TimeInterval = 20) {
        let item = statusItem(application)
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let value = (item.value as? String) ?? ""
                return (item.label + " " + value).localizedCaseInsensitiveContains(state)
            },
            object: item
        )
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: timeout), .completed,
                       "Status item must expose \(state)")
    }

    private func waitForDefaultsAcknowledgement() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                defaults.bool(forKey: "menuBar.didExplainBackgroundRunning")
            },
            object: defaults
        )
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 5), .completed)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed)
    }

    private func waitUntilNotRunning(_ application: XCUIApplication) {
        XCTAssertTrue(application.wait(for: .notRunning, timeout: 20))
    }

    private func element(_ application: XCUIApplication, _ identifier: String) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
