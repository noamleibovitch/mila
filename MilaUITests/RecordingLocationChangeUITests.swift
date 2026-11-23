import XCTest
import AVFoundation
import Carbon

/// Native copy/start-fresh/adopt flow. Every test launches with a clean
/// UUID-owned store root and UUID-owned preferences suite, seeds a synthetic
/// recording, and never asks for microphone or screen-recording permission.
@MainActor
final class RecordingLocationChangeUITests: XCTestCase {
    private var root: URL!
    private var destination: URL!
    private var suiteID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        try selectLiteralKeyboardLayout()
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("Mila-UITest-\(UUID().uuidString)", isDirectory: true)
        destination = base.appendingPathComponent("Mila-UITest-\(UUID().uuidString)", isDirectory: true)
        suiteID = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"),
                                                withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Synthetic bytes only: never the user's recordings, never a real
        // audio capture. The row is seeded by the app's clean-store fixture.
        let audio = root.appendingPathComponent("Recordings/seed.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for frame in 0..<16_000 {
            buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 16_000)) * 0.05
        }
        try file.write(from: buffer)
    }

    private func selectLiteralKeyboardLayout() throws {
        func inputID(_ source: TISInputSource) -> String {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let originalID = inputID(original)
        let enabled = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        let literal = try XCTUnwrap(enabled.first {
            ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(inputID($0))
        }, "Native literal shortcuts require an already-enabled ABC or US layout")
        // Register restoration before selection, including assertion failures.
        // Never enable a layout or write persistent input-source preferences.
        addTeardownBlock {
            XCTAssertEqual(TISSelectInputSource(original), noErr, "Restore original input source")
            XCTAssertEqual(inputID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()), originalID)
            print("Picker keyboard restoration verified")
        }
        XCTAssertEqual(TISSelectInputSource(literal), noErr)
        XCTAssertEqual(inputID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()), inputID(literal))
        print("Picker literal input verified:", inputID(literal))
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: "Mila.StorageUITests.\(suiteID.uuidString)")
        if let root { try? FileManager.default.removeItem(at: root) }
        if let destination { try? FileManager.default.removeItem(at: destination) }
        try await super.tearDown()
    }

    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MILA_UI_TEST_CLEAN_ROOT"] = root.path
        app.launchArguments = [
            "--uitests",
            "--ui-test-clean-store",
            "--ui-test-seed-recording",
            "--ui-test-storage-suite=\(suiteID.uuidString)"
        ] + extraArguments
        app.launch()
        return app
    }

    private func visibleText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: "\n")
    }

    private func openStorage(_ app: XCUIApplication, expectedDirectory: URL? = nil) -> XCUIElement {
        let settingsLink = app.buttons["sidebar.settings.link"]
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 15), "Settings link missing")
        settingsLink.click()
        let storage = app.descendants(matching: .any).matching(identifier: "settings.section.storage").firstMatch
        XCTAssertTrue(storage.waitForExistence(timeout: 10), "Storage section missing")
        storage.click()
        XCTAssertTrue(app.buttons["storage.chooseFolder.button"].waitForExistence(timeout: 10))
        let expected = expectedDirectory ?? root.appendingPathComponent("Recordings")
        let settingsWindow = app.windows.containing(.any, identifier: "settings.section.storage").firstMatch
        // The visible path abbreviates the home directory to ~. Its stable
        // accessibility value carries the full selected directory instead.
        let path = app.descendants(matching: .any).matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5), "Current folder path missing")
        XCTAssertEqual(path.value as? String, expected.path,
                       "App must open the exact expected test library")
        return settingsWindow
    }

    private func chooseDestination(_ app: XCUIApplication, path: URL? = nil) {
        app.buttons["storage.chooseFolder.button"].click()
        completeFolderPanel(app, path: path)
    }

    /// Drive the already-presented native panel. `Choose another folder…`
    /// opens it itself, so retries must not click Settings' Choose again.
    private func completeFolderPanel(_ app: XCUIApplication, path: URL? = nil) {
        // NSOpenPanel.begin presents a standalone open-panel window, not
        // a sheet attached to Settings. Go to Folder is a sheet of that panel.
        let panel = app.windows["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Native folder panel did not appear")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goTo = panel.sheets.firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 5), "Go to Folder did not appear")
        let field = goTo.comboBoxes.firstMatch.exists
            ? goTo.comboBoxes.firstMatch : goTo.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText((path ?? destination).path)
        panel.typeKey(.return, modifierFlags: [])
        let choose = panel.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(app.staticTexts["storage.changeSheet.title"].waitForExistence(timeout: 10),
                      "Choice sheet did not appear")
    }

    /// The app seeds its synthetic library from production Codable types, so
    /// the UI runner writes a populated destination by hand from the same
    /// on-disk schema: a UUID row, ISO-8601 date, completed status, and an
    /// audio file the row names. No Mila model is linked into this target.
    private func seedPopulatedDestination(recordingID: UUID,
                                          audioName: String,
                                          title: String) throws -> (index: Data, audio: Data) {
        let row: [String: Any] = [
            "id": recordingID.uuidString,
            "title": title,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "duration": 2.0,
            "source": "microphone",
            "audioFileName": audioName,
            "status": "completed",
            "language": "en",
            "segments": []
        ]
        let index = try JSONSerialization.data(withJSONObject: [row],
                                               options: [.prettyPrinted, .sortedKeys])
        try index.write(to: destination.appendingPathComponent("recordings.json"), options: .atomic)
        try writeSyntheticWAV(at: destination.appendingPathComponent(audioName),
                              frequency: 220, frames: 8_000)
        return (index, try Data(contentsOf: destination.appendingPathComponent(audioName)))
    }

    private func writeSyntheticWAV(at url: URL, frequency: Double, frames: AVAudioFrameCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * frequency / 16_000)) * 0.05
        }
        try file.write(from: buffer)
    }

    private func indexRows(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Never capture the desktop: only the app window that currently owns the
    /// rendered outcome (falling back to another app window).
    private func appWindowScreenshot(_ app: XCUIApplication, named name: String) {
        let outcomeWindow = app.windows
            .containing(.staticText, identifier: "storage.changeSheet.outcome").firstMatch
        let target = outcomeWindow.exists ? outcomeWindow : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Never capture the desktop: only the explicit app window that owns the
    /// visible Storage section (falling back to another app window).
    private func settingsWindowScreenshot(_ app: XCUIApplication, named name: String) {
        let settingsWindow = app.windows
            .containing(.any, identifier: "settings.section.storage").firstMatch
        let target = settingsWindow.exists ? settingsWindow : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Match a rendered label regardless of the SwiftUI element type: combined
    /// accessibility groups surface their text as a label, not a static text.
    private func renderedElement(_ app: XCUIApplication, labelContains fragment: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
    }

    /// The Settings affordances refuse while any real writer is busy. Wait for
    /// the app's own readiness to settle before driving the chooser in a
    /// scenario that does not itself simulate busy.
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval,
                                  _ message: String) {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.isEnabled },
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: timeout), .completed, message)
    }

    func test_radio_selection_continue_copy_reopen() throws {
        let app = launch()
        _ = openStorage(app)
        chooseDestination(app)
        let continueButton = app.buttons["storage.changeSheet.continue"]
        XCTAssertFalse(continueButton.exists && continueButton.isEnabled,
                       "Continue must start disabled until a deliberate selection")
        let copy = app.radioButtons["Copy recordings and switch"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.click()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 30), "Copy did not settle")
        XCTAssertTrue(visibleText(outcome).contains(destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("recordings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/seed.wav").path),
                      "Originals must remain")

        let copiedAudio = destination.appendingPathComponent("seed.wav")
        XCTAssertEqual(try Data(contentsOf: copiedAudio),
                       try Data(contentsOf: root.appendingPathComponent("Recordings/seed.wav")))
        XCTAssertEqual(try AVAudioFile(forReading: copiedAudio).length, 16_000)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Folder change completed"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Close"].click()
        app.terminate()
        let reopened = launch()
        _ = openStorage(reopened, expectedDirectory: destination)
        let persistedPath = reopened.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertEqual(persistedPath.value as? String, destination.path,
                       "The committed custom folder must persist across reopen")
    }

    func test_start_fresh_and_escape_before_commit() throws {
        let app = launch()
        _ = openStorage(app)
        chooseDestination(app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["storage.changeSheet.title"].waitForExistence(timeout: 2),
                       "Escape must cancel before commit")
        // Reopen and choose Start fresh.
        chooseDestination(app)
        let fresh = app.radioButtons["Start fresh"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 5))
        fresh.click()
        app.buttons["storage.changeSheet.continue"].click()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20))
        XCTAssertTrue(visibleText(outcome).contains("empty recordings list"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("recordings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("seed.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/seed.wav").path))
    }

    func test_existing_zero_row_library_uses_folder_without_merge() throws {
        try Data("[]".utf8).write(to: destination.appendingPathComponent("recordings.json"))
        let app = launch()
        _ = openStorage(app)
        chooseDestination(app)
        let use = app.radioButtons["Use this folder"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.click()
        app.buttons["storage.changeSheet.continue"].click()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20))
        XCTAssertTrue(visibleText(outcome).contains("empty recordings list"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/seed.wav").path))
    }

    func test_use_default_location_same_folder_is_no_op() throws {
        let app = launch()
        _ = openStorage(app)
        app.buttons["storage.resetDefault.button"].click()
        let message = app.staticTexts["Mila is already using this folder."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["storage.changeSheet.title"].exists)
    }

    func test_populated_destination_adoption_preserves_destination_uuid_index_audio_and_source() throws {
        let adoptedID = UUID()
        let adoptedAudioName = "adopted.wav"
        let seeded = try seedPopulatedDestination(recordingID: adoptedID,
                                                  audioName: adoptedAudioName,
                                                  title: "Adopted Recording")
        let sourceRecordings = root.appendingPathComponent("Recordings")
        let sourceAudio = sourceRecordings.appendingPathComponent("seed.wav")

        let app = launch()
        _ = openStorage(app)
        chooseDestination(app)

        let title = app.staticTexts["storage.changeSheet.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(visibleText(title).contains("Change recordings folder"),
                      "A populated non-default destination must render the change-folder title")
        let continueButton = app.buttons["storage.changeSheet.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled,
                       "Continue must stay disabled until the user deliberately chooses")
        let use = app.radioButtons["Use this folder"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.click()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.isEnabled)
        let combine = app.descendants(matching: .any)
            .matching(identifier: "storage.changeSheet.consequence").firstMatch
        XCTAssertTrue(combine.waitForExistence(timeout: 5))
        XCTAssertTrue(visibleText(combine).contains("combine the two folders"),
                      "Adoption warning must state the folders are not merged")

        continueButton.click()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 30), "Adoption did not settle")
        let outcomeText = visibleText(outcome)
        XCTAssertTrue(outcomeText.contains(destination.path))
        XCTAssertTrue(outcomeText.contains("with 1 recording"))
        XCTAssertTrue(outcomeText.contains("combine the two folders"))
        XCTAssertTrue(outcomeText.contains(sourceRecordings.path),
                      "Outcome must point back at the preserved original source")

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("recordings.json")),
                       seeded.index, "Adopted index bytes must be preserved exactly")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(adoptedAudioName)),
                       seeded.audio, "Adopted audio bytes must be preserved exactly")
        let adoptedRows = try indexRows(at: destination.appendingPathComponent("recordings.json"))
        XCTAssertEqual(adoptedRows.count, 1)
        XCTAssertEqual(adoptedRows.first?["id"] as? String, adoptedID.uuidString,
                       "Adopted destination UUID must survive the switch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAudio.path),
                      "Originals must remain")
        XCTAssertEqual(try indexRows(at: root.appendingPathComponent("recordings.json")).count, 1,
                       "The original source library must be untouched")
        appWindowScreenshot(app, named: "Populated destination adopted without merge")
        app.buttons["Close"].click()
        app.terminate()

        let reopened = launch()
        _ = openStorage(reopened, expectedDirectory: destination)
        XCTAssertEqual(try indexRows(at: destination.appendingPathComponent("recordings.json"))
                        .first?["id"] as? String, adoptedID.uuidString,
                       "The adopted UUID must persist across reopen")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(adoptedAudioName)),
                       seeded.audio, "Adopted audio bytes must survive reopen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAudio.path),
                      "Originals must survive reopen")
    }

    func test_unsafe_nested_and_unrelated_destinations_fail_then_safe_retry_succeeds() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let nested = root.appendingPathComponent("NestedUnsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let unrelated = base.appendingPathComponent("Mila-UITest-\(UUID().uuidString)", isDirectory: true)
        let retry = base.appendingPathComponent("Mila-UITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retry, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: unrelated)
            try? FileManager.default.removeItem(at: retry)
        }
        try Data("[]".utf8).write(to: unrelated.appendingPathComponent("recordings.json"))
        try Data("not a Mila library".utf8).write(to: unrelated.appendingPathComponent("notes.txt"))

        let app = launch()
        _ = openStorage(app)

        chooseDestination(app, path: nested)
        let nestedOutcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(nestedOutcome.waitForExistence(timeout: 20),
                      "An unsafe nested folder must render a failure")
        XCTAssertTrue(visibleText(nestedOutcome).contains("outside your current recordings folder"))
        appWindowScreenshot(app, named: "Unsafe nested destination refused")
        let chooseAnotherAfterNested = app.buttons["Choose another folder…"]
        XCTAssertTrue(chooseAnotherAfterNested.waitForExistence(timeout: 5),
                      "A refused folder must offer Choose another folder")
        chooseAnotherAfterNested.click()
        completeFolderPanel(app, path: unrelated)
        let unrelatedOutcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(unrelatedOutcome.waitForExistence(timeout: 20),
                      "A folder with unrelated files must render a failure")
        XCTAssertTrue(visibleText(unrelatedOutcome).contains("already contains other files"))
        appWindowScreenshot(app, named: "Unrelated destination refused")
        let chooseAnotherAfterUnrelated = app.buttons["Choose another folder…"]
        XCTAssertTrue(chooseAnotherAfterUnrelated.waitForExistence(timeout: 5))
        chooseAnotherAfterUnrelated.click()
        completeFolderPanel(app, path: retry)
        let fresh = app.radioButtons["Start fresh"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 5))
        fresh.click()
        app.buttons["storage.changeSheet.continue"].click()
        let success = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(success.waitForExistence(timeout: 20), "Safe retry did not settle")
        XCTAssertTrue(visibleText(success).contains(retry.path))
        XCTAssertTrue(visibleText(success).contains("empty recordings list"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retry.appendingPathComponent("recordings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Recordings/seed.wav").path),
                      "Originals must remain after the refused attempts and the safe retry")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: unrelated.appendingPathComponent("notes.txt").path),
                      "A refused destination's files must not be touched")
        appWindowScreenshot(app, named: "Safe retry after refused destinations succeeded")
    }

    func test_return_to_populated_default_from_custom_reports_count_and_repeated_reset_is_no_op() throws {
        let defaultRecordings = root.appendingPathComponent("Recordings")
        let app = launch()
        _ = openStorage(app)

        chooseDestination(app)
        let copy = app.radioButtons["Copy recordings and switch"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        app.buttons["storage.changeSheet.continue"].click()
        let copyOutcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(copyOutcome.waitForExistence(timeout: 30), "Copy to the custom folder did not settle")
        XCTAssertTrue(visibleText(copyOutcome).contains(destination.path))
        app.buttons["Close"].click()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recordings.json").path))

        app.buttons["storage.resetDefault.button"].click()
        let title = app.staticTexts["storage.changeSheet.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(visibleText(title).contains("Use the default recordings folder"),
                      "A populated default must render the default-folder title")
        let continueButton = app.buttons["storage.changeSheet.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled,
                       "Adopting the populated default must require a deliberate choice")
        let use = app.radioButtons["Use this folder"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.click()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.isEnabled)
        let count = app.descendants(matching: .any)
            .matching(identifier: "storage.changeSheet.consequence").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(visibleText(count).contains("already has 1 recording"),
                      "Warning must report the populated default count")
        let combine = app.descendants(matching: .any)
            .matching(identifier: "storage.changeSheet.consequence").firstMatch
        XCTAssertTrue(combine.waitForExistence(timeout: 5))
        XCTAssertTrue(visibleText(combine).contains("combine the two folders"),
                      "Warning must state the folders are not merged")
        appWindowScreenshot(app, named: "Return to populated default warns count and no merge")

        continueButton.click()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 30), "Return to the default did not settle")
        let outcomeText = visibleText(outcome)
        XCTAssertTrue(outcomeText.contains(defaultRecordings.path))
        XCTAssertTrue(outcomeText.contains("with 1 recording"))
        XCTAssertTrue(outcomeText.contains("combine the two folders"))
        XCTAssertEqual(try indexRows(at: root.appendingPathComponent("recordings.json")).count, 1,
                       "Returning to the default must not merge the custom library into it")
        XCTAssertEqual(try indexRows(at: destination.appendingPathComponent("recordings.json")).count, 1,
                       "The custom library must remain intact after returning to the default")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("seed.wav").path),
                      "The custom copy must not be deleted on return")
        appWindowScreenshot(app, named: "Returned to populated default without merge")
        app.buttons["Close"].click()

        let currentPath = app.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(currentPath.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPath.value as? String, defaultRecordings.path)

        app.buttons["storage.resetDefault.button"].click()
        let noOp = app.staticTexts["Mila is already using this folder."]
        XCTAssertTrue(noOp.waitForExistence(timeout: 10),
                      "Reset while already on the default must report a no-op")
        XCTAssertFalse(app.staticTexts["storage.changeSheet.title"].exists)
        app.buttons["storage.resetDefault.button"].click()
        XCTAssertTrue(noOp.waitForExistence(timeout: 10),
                      "A repeated reset must stay a no-op")
        XCTAssertFalse(app.staticTexts["storage.changeSheet.title"].exists)
        XCTAssertEqual(try indexRows(at: root.appendingPathComponent("recordings.json")).count, 1)
    }

    // MARK: - Insufficient space, synthetic busy, and slow-check cancellation

    func test_insufficient_space_disables_copy_and_cancel_keeps_originals() throws {
        let sourceRecordings = root.appendingPathComponent("Recordings")
        let sourceAudio = sourceRecordings.appendingPathComponent("seed.wav")
        let sourceIndex = root.appendingPathComponent("recordings.json")

        // The DEBUG-only capacity fixture reports one byte free, so the
        // preview must show an honest required/available warning.
        let app = launch(extraArguments: ["--ui-test-folder-scenario=insufficient-space"])
        _ = openStorage(app)
        waitUntilEnabled(app.buttons["storage.chooseFolder.button"], timeout: 10,
                         "The chooser must become available after launch work settles")
        let originalAudio = try Data(contentsOf: sourceAudio)
        let originalIndex = try Data(contentsOf: sourceIndex)
        chooseDestination(app)

        XCTAssertTrue(app.staticTexts["storage.changeSheet.title"].waitForExistence(timeout: 10))
        let warning = renderedElement(app, labelContains: "Not enough space")
        XCTAssertTrue(warning.waitForExistence(timeout: 5),
                      "Insufficient space must render its required/available reason")
        XCTAssertTrue(visibleText(warning).contains("needed"),
                      "The reason must state how much space the copy needs")
        XCTAssertTrue(visibleText(warning).contains("available"),
                      "The reason must state how much space is available")
        let copy = app.radioButtons["Copy recordings and switch"]
        XCTAssertFalse(copy.exists,
                       "A copy the volume cannot hold must not be selectable")
        let fresh = app.radioButtons["Start fresh"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 5),
                      "A safe alternative must remain available")
        let continueButton = app.buttons["storage.changeSheet.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled,
                       "Continue must stay disabled until a deliberate selection")
        settingsWindowScreenshot(app, named: "Insufficient space refuses the copy")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["storage.changeSheet.title"].waitForExistence(timeout: 2),
                       "Escape must cancel before any copy or switch")

        let path = app.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.value as? String, sourceRecordings.path,
                       "Cancel must keep the original folder selected")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recordings.json").path),
                       "No copy may be started for an unaffordable destination")
        XCTAssertEqual(try Data(contentsOf: sourceAudio), originalAudio,
                       "Cancel must not touch the original audio")
        XCTAssertEqual(try Data(contentsOf: sourceIndex), originalIndex,
                       "Cancel must not touch the original index")
    }

    func test_synthetic_busy_settings_shows_visible_feedback_and_refuses_location_actions() throws {
        // This is a SYNTHETIC readiness fixture (labelled as such in its
        // reason): it proves the busy rendering and refusal only, not that a
        // real recording or processing job holds the library. Exercising the
        // real capture/hotkey stack is deliberately out of scope here.
        let app = launch(extraArguments: ["--ui-test-folder-scenario=busy"])
        _ = openStorage(app)

        let choose = app.buttons["storage.chooseFolder.button"]
        XCTAssertTrue(choose.exists)
        XCTAssertFalse(choose.isEnabled, "A busy library must refuse the folder chooser")
        let useDefault = app.buttons["storage.resetDefault.button"]
        XCTAssertTrue(useDefault.exists)
        XCTAssertFalse(useDefault.isEnabled, "A busy library must refuse the default-folder check")
        XCTAssertTrue(renderedElement(app, labelContains: "Synthetic busy state for native verification.")
                        .waitForExistence(timeout: 10),
                      "The busy refusal must be visible, not silent")

        // Keyboard and VoiceOver users receive the refusal through the
        // disabled controls' accessible value.
        let value = (choose.value as? String) ?? ""
        XCTAssertTrue(value.contains("Finish recording or processing before changing folders."),
                      "The disabled control must expose why it refuses")
        XCTAssertTrue(value.contains("Synthetic busy state for native verification."))
        settingsWindowScreenshot(app, named: "Synthetic busy state refuses folder actions")
    }

    func test_slow_check_cancel_settles_and_keeps_originals() throws {
        let sourceRecordings = root.appendingPathComponent("Recordings")
        let sourceAudio = sourceRecordings.appendingPathComponent("seed.wav")
        let sourceIndex = root.appendingPathComponent("recordings.json")

        // The DEBUG-only inspection seam holds the detached check for a
        // bounded twelve seconds so the checking state and its Cancel are
        // reachable without any real cloud/large-folder condition.
        let app = launch(extraArguments: ["--ui-test-folder-scenario=slow-check"])
        _ = openStorage(app)
        waitUntilEnabled(app.buttons["storage.chooseFolder.button"], timeout: 10,
                         "The chooser must become available after launch work settles")
        let originalAudio = try Data(contentsOf: sourceAudio)
        let originalIndex = try Data(contentsOf: sourceIndex)
        chooseDestination(app)

        XCTAssertTrue(renderedElement(app, labelContains: "Checking folder").waitForExistence(timeout: 8),
                      "The bounded inspection hold must expose the checking state")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isEnabled)
        settingsWindowScreenshot(app, named: "Slow folder check in progress")

        cancel.click()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20),
                      "Cancel during checking must settle")
        XCTAssertTrue(visibleText(outcome).contains("Folder check canceled"))
        XCTAssertTrue(visibleText(outcome).contains("still using the current folder"))
        app.buttons["Close"].click()
        XCTAssertFalse(app.staticTexts["storage.changeSheet.title"].waitForExistence(timeout: 2))

        let path = app.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.value as? String, sourceRecordings.path,
                       "A canceled folder check must keep the original folder selected")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recordings.json").path),
                       "A canceled folder check must not write the destination")
        XCTAssertEqual(try Data(contentsOf: sourceAudio), originalAudio,
                       "A canceled folder check must not touch the original audio")
        XCTAssertEqual(try Data(contentsOf: sourceIndex), originalIndex,
                       "A canceled folder check must not touch the original index")
    }
}
