import XCTest
import AppKit
@testable import Mila

@MainActor
final class MenuBarWindowLifecycleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var presentations: [MenuBarFirstCloseNotice] = []
    private var pendingAcknowledgement: (() -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "MenuBarWindowLifecycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        presentations = []
        pendingAcknowledgement = nil
    }

    override func tearDown() async throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeWindow(_ identifier: String = "Mila") -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    private func makeController(
        acknowledgeImmediately: Bool = true,
        status: MenuBarStatus = .ready
    ) -> MenuBarWindowController {
        let controller = MenuBarWindowController(
            defaults: defaults,
            presenter: { _, notice, completion in
                self.presentations.append(notice)
                if acknowledgeImmediately {
                    completion(true)
                } else {
                    self.pendingAcknowledgement = { completion(true) }
                }
            },
            activate: {}
        )
        controller.statusProvider = { status }
        return controller
    }

    func test_close_hides_the_original_window_and_reopen_brings_it_back() {
        let controller = makeController()
        let window = makeWindow()
        controller.attach(window: window)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        window.performClose(nil)

        XCTAssertFalse(window.isVisible, "X must hide, not destroy, the main window")
        XCTAssertEqual(presentations.count, 1)
        XCTAssertTrue(MenuBarFirstCloseStore(defaults: defaults).hasExplained)

        XCTAssertTrue(controller.restoreMainWindow())
        XCTAssertTrue(window.isVisible, "Open Mila must restore the SAME resident window")

        // A second close after the acknowledgement hides with no new sheet.
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(presentations.count, 1, "The explanation is once only")
    }

    func test_window_without_an_original_delegate_is_still_wrapped() {
        let controller = makeController()
        let window = makeWindow()
        XCTAssertNil(window.delegate)
        controller.attach(window: window)
        XCTAssertTrue(window.delegate is MenuBarWindowDelegateProxy,
                      "An absent original delegate must not be mistaken for an installed proxy")
        window.orderFront(nil)
        window.performClose(nil)
        XCTAssertEqual(presentations.count, 1)
        XCTAssertFalse(window.isVisible)
        controller.detach(window: window)
        XCTAssertNil(window.delegate)
    }

    func test_notice_is_once_per_injected_defaults_suite() {
        let first = makeController()
        let firstWindow = makeWindow()
        first.attach(window: firstWindow)
        firstWindow.orderFront(nil)
        firstWindow.performClose(nil)
        XCTAssertEqual(presentations.count, 1)
        first.detach(window: firstWindow)

        // Same suite: no second explanation.
        let sameSuite = makeController()
        let sameWindow = makeWindow()
        sameSuite.attach(window: sameWindow)
        sameWindow.orderFront(nil)
        sameWindow.performClose(nil)
        XCTAssertEqual(presentations.count, 1)
        sameSuite.detach(window: sameWindow)

        // A different test-owned suite has its own acknowledgement state.
        suiteName = "MenuBarWindowLifecycleTests.other.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        let otherSuite = makeController()
        let otherWindow = makeWindow()
        otherSuite.attach(window: otherWindow)
        otherWindow.orderFront(nil)
        otherWindow.performClose(nil)
        XCTAssertEqual(presentations.count, 2)
    }

    func test_notice_copy_tracks_capture_state() {
        let controller = makeController(status: .paused)
        let window = makeWindow()
        controller.attach(window: window)
        window.orderFront(nil)
        window.performClose(nil)

        XCTAssertEqual(presentations.first?.title, "Mila keeps running")
        XCTAssertTrue(presentations.first?.message.contains("Your recording will stay paused.") == true)
        XCTAssertFalse(window.isVisible)
    }

    func test_repeated_close_while_notice_is_pending_is_guarded() {
        let controller = makeController(acknowledgeImmediately: false)
        let window = makeWindow()
        controller.attach(window: window)
        window.orderFront(nil)

        window.performClose(nil)
        window.performClose(nil)

        XCTAssertEqual(presentations.count, 1)
        XCTAssertTrue(window.isVisible, "The window stays up behind the sheet")

        pendingAcknowledgement?()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(MenuBarFirstCloseStore(defaults: defaults).hasExplained)
    }

    func test_settings_window_is_not_registered_and_closes_normally() {
        let controller = makeController()
        let main = makeWindow()
        controller.attach(window: main)
        main.orderFront(nil)

        let settings = makeWindow("com_apple_SwiftUI_Settings_window")
        settings.orderFront(nil)
        controller.attach(window: settings)
        XCTAssertTrue(controller.mainWindow === main,
                      "Only the first/main window may be resident")

        settings.performClose(nil)
        XCTAssertFalse(settings.isVisible)
        XCTAssertEqual(presentations.count, 0, "Settings close must never show the notice")
        XCTAssertTrue(main.isVisible, "Closing Settings must not hide the main window")
    }

    func test_quit_allows_close_without_explanation() {
        let controller = makeController()
        let window = makeWindow()
        controller.attach(window: window)
        window.orderFront(nil)

        controller.beginTermination()
        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(presentations.count, 0, "Quit must not block on the background notice")
        XCTAssertFalse(MenuBarFirstCloseStore(defaults: defaults).hasExplained)
    }

    func test_minimized_window_is_deminiaturized_by_restore() async {
        let controller = makeController()
        let window = makeWindow()
        controller.attach(window: window)
        window.orderFront(nil)
        window.miniaturize(nil)
        let minimized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.isMiniaturized }, object: window)
        await fulfillment(of: [minimized], timeout: 3)
        XCTAssertTrue(window.isMiniaturized)

        XCTAssertTrue(controller.restoreMainWindow())
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !window.isMiniaturized && window.isVisible }, object: window)
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible)
    }

    func test_reveal_if_hidden_only_acts_when_not_usable() {
        let controller = makeController()
        let window = makeWindow()
        controller.attach(window: window)
        window.orderFront(nil)

        // Visible: no focus theft.
        controller.revealIfHidden()
        XCTAssertTrue(window.isVisible)

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        controller.revealIfHidden()
        XCTAssertTrue(window.isVisible)
    }

    func test_dock_reopen_restores_the_resident_window_and_last_close_does_not_quit() {
        let delegate = MilaAppDelegate()
        let window = makeWindow()
        delegate.menuBarWindow.attach(window: window)
        window.orderFront(nil)
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertTrue(handled)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                       "The app must stay alive after the last window is hidden/closed")
    }

    func test_swiftui_original_delegate_still_receives_optional_callbacks() {
        final class OriginalDelegate: NSObject, NSWindowDelegate {
            var becameKey = 0
            func windowDidBecomeKey(_ notification: Notification) { becameKey += 1 }
        }
        let original = OriginalDelegate()
        let controller = makeController()
        let window = makeWindow()
        window.delegate = original

        controller.attach(window: window)
        guard let proxy = window.delegate as? MenuBarWindowDelegateProxy else {
            return XCTFail("The main window must be wrapped by the forwarding proxy")
        }
        XCTAssertFalse((window.delegate as AnyObject?) === original)

        let delegate: NSWindowDelegate = proxy
        delegate.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification,
                                                  object: window))
        XCTAssertEqual(original.becameKey, 1,
                       "SwiftUI's optional delegate behaviour must be forwarded, not replaced")

        controller.detach(window: window)
        XCTAssertTrue((window.delegate as AnyObject?) === original,
                      "Dismantling must restore the original delegate")
        XCTAssertNil(controller.mainWindow)
    }
}
