import XCTest

/// Native batch-only capture/Stop/save/reopen using synthetic audio and the
/// existing isolated auto-save fixture host. No microphone or personal data.
final class BatchOnlyRecordingUITests: XCTestCase {
    private var app: XCUIApplication?
    private var suiteID: UUID!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        suiteID = UUID()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mila.BatchOnlyUITests.\(suiteID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let suiteID {
            UserDefaults().removePersistentDomain(forName: "Mila.AutoSaveUITests.\(suiteID.uuidString)")
        }
        if let tempRoot { try FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    func test_batch_only_saves_and_reopens_fixture_transcript() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MILA_BATCH_UI_E2E"] == "1",
                          "Requires an unlocked Mac and local synthetic WAV/tiny model fixtures.")
        let wav = try fixturePath("MILA_FIXTURE_WAV_PATH")
        let tiny = try fixturePath("MILA_TINY_MODEL_PATH")
        // The target seeds typed preferences in its own UUID-owned suite,
        // avoiding cross-process defaults and the physical mic settings meter.
        let application = launch(wav: wav, tiny: tiny)

        let stop = element(application, "home.record.hero")
        XCTAssertTrue(stop.waitForExistence(timeout: 30))
        // The Home-only Pause control exists only during an active capture.
        // Do not infer recording state from a SwiftUI button's combined AX
        // caption, which macOS can expose on a child rather than the button.
        XCTAssertTrue(element(application, "recording.pause").waitForExistence(timeout: 30))
        XCTAssertFalse(element(application, "liveAI.stop").exists,
                       "The fixture must use batch Home capture, not the live pane")
        let recording = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            stop.isHittable && stop.isEnabled
        }, object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 30), .completed,
                       "Batch-only capture must offer an enabled Stop without a live transcript")
        XCTAssertFalse(element(application, "liveTranscript.segment").exists)
        XCTAssertFalse(element(application, "home.record.preparing.spinner").exists)
        stop.click()

        let title = element(application, "detail.title.label")
        XCTAssertTrue(title.waitForExistence(timeout: 60), "Auto-save must open the saved recording")
        XCTAssertFalse(application.staticTexts["Name this recording"].exists)
        let transcript = application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "account", "account")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 180),
                      "Stop must run real local batch transcription of en_meeting_notes.wav")
        let savedTitle = title.label.isEmpty ? (title.value as? String ?? "") : title.label
        XCTAssertFalse(savedTitle.isEmpty)
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = "Synthetic batch transcript after Stop"
        attachment.lifetime = .keepAlways
        add(attachment)

        application.staticTexts["Home"].firstMatch.click()
        XCTAssertTrue(element(application, "home.record.hero").waitForExistence(timeout: 10))
        element(application, "sidebar.folder.default").click()
        let row = element(application, "history.row.\(savedTitle)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(transcript.waitForExistence(timeout: 10),
                      "Reopening must retain the batch transcript")
    }

    private func launch(wav: String? = nil, tiny: String) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--uitests", "--ui-test-clean-store", "--ui-test-recording-lang-en",
            "--ui-test-batch-recording",
            "--ui-test-auto-save-suite=\(suiteID.uuidString)",
            "--ui-test-tiny-model-path=\(tiny)",
            "-diarization.enabled", "NO", "-speakers.voiceRecognition.enabled", "NO",
            "-llm.tool", "none", "-llm.name.enabled", "NO",
            "-llm.summary.enabled", "NO", "-llm.action.enabled", "NO",
            "-transcription.backend", "local",
        ]
        if let wav { application.launchArguments.append("--ui-test-inject-fixture-wav=\(wav)") }
        application.launchEnvironment["TMPDIR"] = tempRoot.path + "/"
        app = application
        application.launch()
        return application
    }

    private func element(_ application: XCUIApplication, _ identifier: String) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func fixturePath(_ key: String) throws -> String {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Missing synthetic fixture: \(key)")
        return path
    }
}
