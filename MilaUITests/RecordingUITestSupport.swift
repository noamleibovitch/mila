import Carbon
import XCTest

/// Shared synthetic recording fixtures and macOS accessibility observations.
@MainActor
protocol RecordingUITestSupport: AnyObject {}

extension RecordingUITestSupport where Self: XCTestCase {
    func makeRecordingUITestRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("Mila-UITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    func selectLiteralKeyboardLayout() throws {
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

    func visibleText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: "\n")
    }

    func waitForNonExistence(_ element: XCUIElement,
                                     timeout: TimeInterval = 10,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Element must disappear", file: file, line: line)
    }

    func meterPercent(_ element: XCUIElement) -> Int? {
        Self.meterPercent(value: element.value as? String, label: element.label)
    }

    static func meterPercent(value: String?, label: String) -> Int? {
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

    func waitForMeter(_ element: XCUIElement,
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

    /// The controller maps a live app-audio permission failure onto the
    /// existing system permission alert as well as the inline message. Read
    /// that alert and cancel it so the inline, persistent Unavailable state
    /// can be inspected; never open System Settings.
    func dismissPermissionAlertIfPresent(_ app: XCUIApplication) {
        // SwiftUI presents this permission alert as a sheet on macOS.
        // Cancel the actual modal before interacting with its parent window.
        let sheet = app.sheets.firstMatch
        let alert = sheet.waitForExistence(timeout: 5) ? sheet : app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Permission alert must be located before testing its parent")
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Permission alert must offer Cancel")
        cancel.click()
        waitForNonExistence(alert)
    }

    func meter(_ app: XCUIApplication, labeled label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ", "))
            .firstMatch
    }
}
