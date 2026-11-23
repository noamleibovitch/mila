import AppKit
import XCTest
@testable import Mila

@MainActor
final class RecordingLocationTerminationBridgeTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func test_copy_allows_delegate_then_idle_and_detach_restore_sheet_policy() {
        let window = window()
        defer { window.close() }
        window.preventsApplicationTerminationWhenModal = true
        let view = RecordingLocationTerminationBridge.AttachmentView()
        window.contentView = view
        view.configure(allowsTerminationRequest: true)
        XCTAssertFalse(window.preventsApplicationTerminationWhenModal)
        view.configure(allowsTerminationRequest: false)
        XCTAssertTrue(window.preventsApplicationTerminationWhenModal)
        view.configure(allowsTerminationRequest: true)
        view.detach()
        XCTAssertTrue(window.preventsApplicationTerminationWhenModal)
    }

    func test_reparent_restores_only_previous_window_and_keeps_original_false() {
        let first = window(), second = window(), unrelated = window()
        defer { first.close(); second.close(); unrelated.close() }
        first.preventsApplicationTerminationWhenModal = true
        second.preventsApplicationTerminationWhenModal = false
        unrelated.preventsApplicationTerminationWhenModal = true
        let view = RecordingLocationTerminationBridge.AttachmentView()
        view.configure(allowsTerminationRequest: true)
        first.contentView = view
        XCTAssertFalse(first.preventsApplicationTerminationWhenModal)
        first.contentView = NSView()
        second.contentView = view
        XCTAssertTrue(first.preventsApplicationTerminationWhenModal)
        XCTAssertFalse(second.preventsApplicationTerminationWhenModal)
        view.configure(allowsTerminationRequest: false)
        view.detach()
        XCTAssertFalse(second.preventsApplicationTerminationWhenModal)
        XCTAssertTrue(unrelated.preventsApplicationTerminationWhenModal)
    }
}
