import SwiftUI
import AppKit

/// Mounts the resident-window registration on the main ContentView only.
/// The app delegate owns the controller; this view never does.
@MainActor
struct MenuBarMainWindowBridge: NSViewRepresentable {
    let controller: MenuBarWindowController

    func makeNSView(context: Context) -> MenuBarWindowAttachmentView {
        let view = MenuBarWindowAttachmentView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: MenuBarWindowAttachmentView, context: Context) {
        nsView.controller = controller
        nsView.attachIfPossible()
    }

    static func dismantleNSView(_ nsView: MenuBarWindowAttachmentView, coordinator: ()) {
        nsView.detach()
    }
}

@MainActor
final class MenuBarWindowAttachmentView: NSView {
    weak var controller: MenuBarWindowController?
    private weak var attachedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            attachIfPossible()
        }
    }

    func attachIfPossible() {
        guard let window else { return }
        attachedWindow = window
        controller?.attach(window: window)
    }

    func detach() {
        guard let attachedWindow else { return }
        controller?.detach(window: attachedWindow)
        self.attachedWindow = nil
    }
}
