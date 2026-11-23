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
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                  fragment, fragment))
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

    // MARK: - Interrupted-copy helpers (mid-copy progress, Quit, cold removal)

    /// Grow the app-seeded audio inside the UI-owned clean root BEFORE launch so
    /// a copy spans several 1 MiB worker chunks. This is a few megabytes of
    /// synthetic sine audio, never user audio, and it is removed with the root.
    private func growSeedWAV(frames: AVAudioFrameCount) throws {
        let audio = root.appendingPathComponent("Recordings/seed.wav")
        try? FileManager.default.removeItem(at: audio)
        try writeSyntheticWAV(at: audio, frequency: 440, frames: frames)
    }

    private struct InterruptedCopyFixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Must match `RecordingLocationUITestHarness.releaseMarkerName` in the app
    /// target (that type is DEBUG-only and not linked into this UI test target,
    /// so the single fixed name is mirrored here with the same literal).
    private static let copyGateReleaseMarkerName = "Mila-UITest-copy-gate-release"

    /// The combined copy-progress accessibility element, addressed by its
    /// stable identifier rather than by a guessed label or element type.
    private func copyProgressElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "storage.changeSheet.copyProgress")
            .firstMatch
    }

    /// The single release marker the DEBUG harness polls, inside this test's
    /// already-validated UUID clean root. The test is the sole writer.
    private var copyGateReleaseURL: URL {
        root.appendingPathComponent(Self.copyGateReleaseMarkerName, isDirectory: false)
    }

    /// Release the held copy worker. Unconditional and idempotent so it is safe
    /// in a `defer` on a failed assertion; it never writes outside the root.
    private func releaseCopyGate() {
        let url = copyGateReleaseURL
        if FileManager.default.fileExists(atPath: url.path) { return }
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    private func boundedDiagnostic(_ text: String, limit: Int = 200) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// Bounded, synthetic-only snapshot of the actual accessibility label and
    /// value, so a parser mismatch is diagnosed from observed values instead
    /// of guessed. Contains only fixture UI text, never user data.
    private func copyProgressDiagnostic(_ app: XCUIApplication) -> String {
        let element = copyProgressElement(app)
        guard element.exists else {
            return "element missing (identifier storage.changeSheet.copyProgress)"
        }
        let label = boundedDiagnostic(element.label)
        let value = boundedDiagnostic((element.value as? String) ?? "<nil>")
        return "label=\(label) value=\(value)"
    }

    /// The copy view is one combined accessibility element whose value is
    /// "done of total files, copied of total bytes". Wait until the copied
    /// portion is a real KB/MB amount, so a pass proves observed byte progress
    /// rather than only the copying phase. Throws fail-fast (ending the test
    /// body) if the element never appears or never reports nonzero bytes, so
    /// later stage checks never run against a stale or completed stage.
    @discardableResult
    private func waitForRealCopyProgress(_ app: XCUIApplication,
                                         timeout: TimeInterval = 25) throws -> XCUIElement {
        let element = copyProgressElement(app)
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Copy progress must be visible; \(copyProgressDiagnostic(app))")
            throw InterruptedCopyFixtureError("copy progress element never appeared")
        }
        let progressed = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let value = (element.value as? String) ?? ""
            let text = value.isEmpty ? element.label : value
            guard let marker = text.range(of: "files, ") else { return false }
            let copied = String(text[marker.upperBound...])
                .components(separatedBy: " of ").first ?? ""
            return copied.contains("KB") || copied.contains("MB")
        }, object: element)
        guard XCTWaiter.wait(for: [progressed], timeout: timeout) == .completed else {
            XCTFail("Copy progress must report real copied bytes, not only the phase; \(copyProgressDiagnostic(app))")
            throw InterruptedCopyFixtureError("copy progress never reported nonzero bytes")
        }
        return element
    }

    private func incompleteStageDirectories(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(".mila-copy-") }
            .map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    private func stagedFileSize(_ stage: URL, named name: String) -> UInt64 {
        let file = stage
            .appendingPathComponent(".mila-copy-files", isDirectory: true)
            .appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The inspected production Quit branch is `applicationShouldTerminate`
    /// (window close does not quit: `applicationShouldTerminateAfterLastWindowClosed`
    /// returns false). Use the app's observed native terminate: menu item.
    /// Cmd-Q produced no handler entry in the confirmed file-trace diagnostic;
    /// the Stop-and-quit case also exercises Cmd-Q after the sheet policy fix.
    @discardableResult
    private func captureFolderQuitTrace(_ phase: String) -> String {
        let url = root.appendingPathComponent("Mila-UITest-quit-trace.txt")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 8_192,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("FolderQuitDiagnostic file: \(phase) unavailable")
            return ""
        }
        print("FolderQuitDiagnostic file: \(phase) \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Folder Quit \(phase) app trace"
        attachment.lifetime = .keepAlways
        add(attachment)
        return text
    }

    private func requestQuit(_ app: XCUIApplication, viaKeyboard: Bool = false) throws {
        let bootTrace = captureFolderQuitTrace("before Quit menu")
        guard bootTrace.split(separator: "\n").contains("wired") else {
            XCTFail("The app-side Quit trace must be live before clicking Quit")
            throw InterruptedCopyFixtureError("app-side Quit trace unavailable")
        }
        func snapshot(_ phase: String) {
            print("FolderQuitDiagnostic UI: \(phase) state=\(app.state.rawValue)")
            guard app.state != .notRunning, app.state != .unknown else { return }
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Folder Quit \(phase) app hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            if app.windows.firstMatch.exists {
                let window = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                window.name = "Folder Quit \(phase) app window"
                window.lifetime = .keepAlways
                add(window)
            }
        }
        if viaKeyboard {
            snapshot("before Cmd-Q")
            app.typeKey("q", modifierFlags: [.command])
            snapshot("after Cmd-Q")
            captureFolderQuitTrace("after Cmd-Q")
            return
        }
        snapshot("before Quit menu")
        // These titles/identifier are present in the captured native app menu,
        // distinct from the status-item menu that has had presentation failures.
        let appMenu = app.menuBars.menuBarItems["Mila"]
        guard appMenu.waitForExistence(timeout: 5), appMenu.isHittable else {
            XCTFail("The native Mila application menu must be visible")
            throw InterruptedCopyFixtureError("native application menu unavailable")
        }
        appMenu.click()
        let quit = appMenu.menuItems["terminate:"]
        guard quit.waitForExistence(timeout: 5), quit.isEnabled, quit.isHittable else {
            snapshot("Quit menu unavailable")
            XCTFail("The native terminate: item must be enabled and visible")
            throw InterruptedCopyFixtureError("native Quit item unavailable")
        }
        quit.click()
        snapshot("after Quit menu")
        captureFolderQuitTrace("after Quit menu")
    }

    private func waitForRemovalConfirmation(_ app: XCUIApplication,
                                            timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var candidates: [XCUIElement] = [app.dialogs.firstMatch]
            candidates.append(contentsOf: app.sheets.allElementsBoundByIndex)
            // Select the inner native alert, not the enclosing folder sheet
            // whose own Remove button has the same title.
            for candidate in candidates where candidate.exists && candidate.label == "alert" {
                if candidate.buttons["Cancel"].exists,
                   candidate.buttons["action-button-1"].exists {
                    return candidate
                }
            }
            _ = RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("Removal confirmation must appear")
        return app.dialogs.firstMatch
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
        settingsWindowScreenshot(app, named: "Insufficient space before warning verification")
        let warning = app.descendants(matching: .any)
            .matching(identifier: "storage.changeSheet.spaceWarning").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5),
                      "Insufficient space must render its required/available reason")
        XCTAssertTrue(visibleText(warning).contains("Not enough space"))
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
        let busyReason = app.descendants(matching: .any)
            .matching(identifier: "storage.busyReason").firstMatch
        XCTAssertTrue(busyReason.waitForExistence(timeout: 10))
        XCTAssertTrue(visibleText(busyReason).contains("Synthetic busy state for native verification."),
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

    // MARK: - Interrupted copy, Quit default, cold incomplete-copy removal

    func test_mid_copy_progress_cancel_retains_incomplete_copy_and_keeps_originals() throws {
        let sourceRecordings = root.appendingPathComponent("Recordings")
        let sourceAudio = sourceRecordings.appendingPathComponent("seed.wav")
        let sourceIndex = root.appendingPathComponent("recordings.json")
        try growSeedWAV(frames: 1_500_000)
        let originalAudio = try Data(contentsOf: sourceAudio)

        let app = launch(extraArguments: ["--ui-test-folder-scenario=slow-copy"])
        defer { app.terminate() }
        // Fail-safe: release the held worker even if an assertion throws, so
        // teardown/app termination never waits on the gate.
        defer { releaseCopyGate() }
        _ = openStorage(app)
        waitUntilEnabled(app.buttons["storage.chooseFolder.button"], timeout: 10,
                         "The chooser must become available after launch work settles")
        let originalIndex = try Data(contentsOf: sourceIndex)
        chooseDestination(app)
        let copy = app.radioButtons["Copy recordings and switch"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        app.buttons["storage.changeSheet.continue"].click()

        try waitForRealCopyProgress(app)
        settingsWindowScreenshot(app, named: "Copying with real byte progress before cancel")
        let midStages = incompleteStageDirectories(in: destination)
        guard midStages.count == 1, let midStage = midStages.first else {
            return XCTFail("The copy must own exactly one hidden stage; found \(midStages.count)")
        }
        XCTAssertGreaterThan(stagedFileSize(midStage, named: "seed.wav"), 0,
                             "The stage must contain real copied bytes before Cancel")

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        // The real cancel is registered; now let the held worker settle.
        releaseCopyGate()

        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 30), "Cancel during copy must settle")
        let text = visibleText(outcome)
        XCTAssertTrue(text.contains("Copy canceled"), "Cancel must not claim success")
        XCTAssertTrue(text.contains("original recordings are unchanged"))
        XCTAssertTrue(text.contains("retained the incomplete copy"),
                      "Unproven staged bytes must be retained, not claimed cleaned up")
        XCTAssertTrue(text.contains("verify safe removal"))
        appWindowScreenshot(app, named: "Cancel during copy retained the incomplete copy")
        app.buttons["Close"].click()

        let currentPath = app.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(currentPath.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPath.value as? String, sourceRecordings.path,
                       "A canceled copy must keep the original folder selected")
        XCTAssertEqual(try Data(contentsOf: sourceAudio), originalAudio,
                       "Cancel must not touch the original audio")
        XCTAssertEqual(try Data(contentsOf: sourceIndex), originalIndex,
                       "Cancel must not touch the original index")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recordings.json").path),
                       "A canceled copy must not publish a destination library")
        let retainedStages = incompleteStageDirectories(in: destination)
        guard retainedStages.count == 1, let retainedStage = retainedStages.first else {
            return XCTFail("A canceled copy whose ownership is unproven must stay on disk as exactly one stage; found \(retainedStages.count)")
        }
        XCTAssertGreaterThan(stagedFileSize(retainedStage, named: "seed.wav"), 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retainedStage.appendingPathComponent(".mila-receipt.json").path),
                      "The retained stage must keep its real receipt")
    }

    func test_quit_during_copy_keep_copying_default_finishes_copy() throws {
        let sourceRecordings = root.appendingPathComponent("Recordings")
        let sourceAudio = sourceRecordings.appendingPathComponent("seed.wav")
        let sourceIndex = root.appendingPathComponent("recordings.json")
        try growSeedWAV(frames: 1_500_000)
        let originalAudio = try Data(contentsOf: sourceAudio)

        let app = launch(extraArguments: ["--ui-test-folder-scenario=slow-copy"])
        defer { app.terminate() }
        // Fail-safe: release the held worker even if an assertion throws.
        defer { releaseCopyGate() }
        _ = openStorage(app)
        waitUntilEnabled(app.buttons["storage.chooseFolder.button"], timeout: 10,
                         "The chooser must become available after launch work settles")
        let originalIndex = try Data(contentsOf: sourceIndex)
        let sourceID = try XCTUnwrap(try indexRows(at: sourceIndex).first?["id"] as? String)
        chooseDestination(app)
        let copy = app.radioButtons["Copy recordings and switch"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        app.buttons["storage.changeSheet.continue"].click()
        try waitForRealCopyProgress(app)

        try requestQuit(app)
        let quitDialog = app.dialogs["alert"]
        XCTAssertTrue(quitDialog.waitForExistence(timeout: 15),
                      "Quit during copy must ask, with Keep copying as the default button")
        captureFolderQuitTrace("after Keep choice wait")
        let keep = quitDialog.buttons["action-button-1"]
        let stop = quitDialog.buttons["action-button-2"]
        XCTAssertTrue(keep.exists)
        XCTAssertTrue(stop.exists)
        XCTAssertEqual(keep.title, "Keep copying")
        XCTAssertEqual(stop.title, "Stop and quit")
        XCTAssertTrue(quitDialog.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                  "Stop copying and quit?", "Stop copying and quit?"))
            .firstMatch.waitForExistence(timeout: 5),
                      "Quit during copy must show the inspected alert title")
        XCTAssertTrue(quitDialog.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                  "Keep copying to finish the folder change",
                                  "Keep copying to finish the folder change"))
            .firstMatch.exists,
                      "The quit alert must explain the default and the stop choice")

        // Exercise the actual default action, rather than inferring it from
        // AX traversal order (which is spatial and includes Touch Bar copies).
        app.typeKey(.return, modifierFlags: [])
        XCTAssertNotEqual(app.state, .notRunning, "Keep copying must cancel the quit")
        // Keep copying is the real chosen action; let the held worker finish.
        releaseCopyGate()
        let outcome = app.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 60),
                      "Keeping the copy running must let it finish")
        let text = visibleText(outcome)
        XCTAssertTrue(text.contains(destination.path))
        XCTAssertTrue(text.contains("original recordings remain"))
        appWindowScreenshot(app, named: "Keep copying default finished the folder change")
        app.buttons["Close"].click()

        let currentPath = app.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(currentPath.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPath.value as? String, destination.path,
                       "The finished copy must be the active folder")
        XCTAssertEqual(try Data(contentsOf: sourceAudio), originalAudio,
                       "The original audio must survive the copy")
        XCTAssertEqual(try Data(contentsOf: sourceIndex), originalIndex,
                       "The original index must survive the copy")
        let destinationIndex = destination.appendingPathComponent("recordings.json")
        let destinationAudio = destination.appendingPathComponent("seed.wav")
        XCTAssertEqual(try Data(contentsOf: destinationIndex), originalIndex,
                       "The copy must preserve raw index bytes")
        XCTAssertEqual(try indexRows(at: destinationIndex).first?["id"] as? String, sourceID,
                       "The copy must preserve the recording UUID")
        XCTAssertEqual(try Data(contentsOf: destinationAudio), originalAudio,
                       "The copy must preserve audio bytes")
        XCTAssertEqual(try AVAudioFile(forReading: destinationAudio).length, 1_500_000)
        XCTAssertTrue(incompleteStageDirectories(in: destination).isEmpty,
                      "A successful copy must remove its verified stage")

        app.terminate()
        let reopened = launch()
        defer { reopened.terminate() }
        _ = openStorage(reopened, expectedDirectory: destination)
        let persistedPath = reopened.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertEqual(persistedPath.value as? String, destination.path,
                       "The committed copy must persist across reopen")
        XCTAssertEqual(try indexRows(at: destinationIndex).first?["id"] as? String, sourceID)
        XCTAssertEqual(try Data(contentsOf: destinationAudio), originalAudio)
    }

    func test_quit_stop_copy_then_cold_reselect_remove_incomplete_copy_safe_failure_retains_files() throws {
        let sourceRecordings = root.appendingPathComponent("Recordings")
        let sourceAudio = sourceRecordings.appendingPathComponent("seed.wav")
        let sourceIndex = root.appendingPathComponent("recordings.json")
        try growSeedWAV(frames: 1_500_000)
        let originalAudio = try Data(contentsOf: sourceAudio)

        let app = launch(extraArguments: ["--ui-test-folder-scenario=slow-copy"])
        defer { app.terminate() }
        // Fail-safe: release the held worker even if an assertion throws, so a
        // failed Stop-and-quit assertion cannot leave the worker parked.
        defer { releaseCopyGate() }
        _ = openStorage(app)
        waitUntilEnabled(app.buttons["storage.chooseFolder.button"], timeout: 10,
                         "The chooser must become available after launch work settles")
        let originalIndex = try Data(contentsOf: sourceIndex)
        chooseDestination(app)
        let copy = app.radioButtons["Copy recordings and switch"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        app.buttons["storage.changeSheet.continue"].click()
        try waitForRealCopyProgress(app)

        try requestQuit(app, viaKeyboard: true)
        let quitDialog = app.dialogs["alert"]
        XCTAssertTrue(quitDialog.waitForExistence(timeout: 15),
                      "Quit during copy must offer Stop and quit")
        captureFolderQuitTrace("after Stop choice wait")
        let stop = quitDialog.buttons["action-button-2"]
        XCTAssertEqual(stop.title, "Stop and quit")
        stop.click()
        // Stop and quit has registered cancellation; release the held worker
        // so settlement and termination can complete.
        releaseCopyGate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 40),
                      "Stop and quit must terminate after the worker settles and cleanup runs")

        // The worker stopped mid-copy, so the durable receipt has no per-file
        // creation identity. Keep using that REAL canceled stage: it must be
        // retained, and no ownership may be fabricated for it.
        let canceledStages = incompleteStageDirectories(in: destination)
        guard canceledStages.count == 1, let canceledStage = canceledStages.first else {
            return XCTFail("The stopped copy must leave exactly one real stage; found \(canceledStages.count)")
        }
        let partialSize = stagedFileSize(canceledStage, named: "seed.wav")
        XCTAssertGreaterThan(partialSize, 0, "The canceled stage holds real copied bytes")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: canceledStage.appendingPathComponent(".mila-receipt.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recordings.json").path))
        XCTAssertEqual(try Data(contentsOf: sourceAudio), originalAudio)
        XCTAssertEqual(try Data(contentsOf: sourceIndex), originalIndex)

        // Test-owned sentinel OUTSIDE the stage: safe removal must never
        // recursively delete the destination. It is not ownership proof and
        // the expected refusal comes from the stage's missing created identity.
        try Data("keep".utf8).write(to: destination.appendingPathComponent("sentinel-keep.txt"))

        let reopened = launch()
        defer { reopened.terminate() }
        _ = openStorage(reopened)
        chooseDestination(reopened)

        XCTAssertTrue(renderedElement(reopened,
                                     labelContains: "incomplete copy from an earlier attempt")
                        .waitForExistence(timeout: 15),
                      "A cold reselect must surface the real incomplete copy")
        XCTAssertTrue(renderedElement(reopened, labelContains: "Remove the incomplete copy").exists)
        let remove = reopened.buttons["Remove incomplete copy"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        let confirmation = waitForRemovalConfirmation(reopened)
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            "Remove the incomplete copy?", "Remove the incomplete copy?"))
            .firstMatch.exists,
                      "Removal must be confirmed explicitly")
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            "original recordings are not removed", "original recordings are not removed"))
            .firstMatch.exists,
                      "The confirmation must state that originals are not removed")
        let attachment = XCTAttachment(screenshot: reopened.windows.firstMatch.screenshot())
        attachment.name = "Incomplete copy removal confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)
        let cancelRemoval = confirmation.buttons["Cancel"]
        XCTAssertTrue(cancelRemoval.waitForExistence(timeout: 5))
        cancelRemoval.click()
        XCTAssertEqual(incompleteStageDirectories(in: destination).count, 1,
                       "Canceling the confirmation must remove nothing")

        remove.click()
        let confirmed = waitForRemovalConfirmation(reopened)
        let destructive = confirmed.buttons["action-button-1"]
        XCTAssertTrue(destructive.waitForExistence(timeout: 5))
        XCTAssertEqual(destructive.title, "Remove incomplete copy")
        destructive.click()

        let outcome = reopened.staticTexts["storage.changeSheet.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 20),
                      "Unsafe incomplete-copy removal must settle")
        let text = visibleText(outcome)
        XCTAssertTrue(text.contains("remove the incomplete copy safely"))
        XCTAssertTrue(text.contains("Choose another folder"))
        XCTAssertFalse(text.contains("Mila removed the incomplete copy"),
                       "Unproven staged files must never be reported as removed")

        let currentPath = reopened.descendants(matching: .any)
            .matching(identifier: "storage.currentFolder.path").firstMatch
        XCTAssertTrue(currentPath.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPath.value as? String, sourceRecordings.path,
                       "A safe-removal failure must keep the original folder selected")

        let retained = incompleteStageDirectories(in: destination)
        guard retained.count == 1, let retainedStage = retained.first else {
            return XCTFail("A safe-removal failure must retain exactly one stage; found \(retained.count)")
        }
        XCTAssertEqual(stagedFileSize(retainedStage, named: "seed.wav"), partialSize,
                       "A safe-removal failure must not truncate or delete staged bytes")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retainedStage.appendingPathComponent(".mila-receipt.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("sentinel-keep.txt").path),
                      "Safe refusal must not recursively delete the destination")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recordings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("seed.wav").path))
        XCTAssertEqual(try Data(contentsOf: sourceAudio), originalAudio)
        XCTAssertEqual(try Data(contentsOf: sourceIndex), originalIndex)
    }
}
