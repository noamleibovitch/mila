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

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MILA_UI_TEST_CLEAN_ROOT"] = root.path
        app.launchArguments = [
            "--uitests",
            "--ui-test-clean-store",
            "--ui-test-seed-recording",
            "--ui-test-storage-suite=\(suiteID.uuidString)"
        ]
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
        // Selectable SwiftUI Text is exposed as a text view rather than
        // StaticText. Keep the exact path assertion, scoped to Settings.
        XCTAssertTrue(settingsWindow.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", expected.path, expected.path)).firstMatch
            .waitForExistence(timeout: 5), "App must open the exact expected test library")
        return settingsWindow
    }

    private func chooseDestination(_ app: XCUIApplication) {
        app.buttons["storage.chooseFolder.button"].click()
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
        field.typeText(destination.path)
        panel.typeKey(.return, modifierFlags: [])
        let choose = panel.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(app.staticTexts["storage.changeSheet.title"].waitForExistence(timeout: 10),
                      "Choice sheet did not appear")
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
        let settingsWindow = reopened.windows.containing(.any, identifier: "settings.section.storage").firstMatch
        XCTAssertTrue(settingsWindow.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", destination.path, destination.path)).firstMatch
            .waitForExistence(timeout: 10), "The committed custom folder must persist across reopen")
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
}
