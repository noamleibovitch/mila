import AppKit
import SwiftUI

/// AppKit normally rejects Quit before asking the delegate while a sheet is
/// open. Only the folder sheet's active copy allows the existing delegate
/// confirmation and bounded settlement to handle termination instead.
@MainActor
struct RecordingLocationTerminationBridge: NSViewRepresentable {
    let allowsTerminationRequest: Bool

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.setAccessibilityElement(false)
        view.configure(allowsTerminationRequest: allowsTerminationRequest)
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        view.configure(allowsTerminationRequest: allowsTerminationRequest)
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: ()) {
        view.detach()
    }

    @MainActor
    final class AttachmentView: NSView {
        private var allowsTerminationRequest = false
        private weak var attachedWindow: NSWindow?
        private var originalPrevention = true

        func configure(allowsTerminationRequest: Bool) {
            self.allowsTerminationRequest = allowsTerminationRequest
            attachIfPossible()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfPossible()
        }

        private func attachIfPossible() {
            if attachedWindow !== window {
                detach()
                if let window {
                    attachedWindow = window
                    originalPrevention = window.preventsApplicationTerminationWhenModal
                }
            }
            attachedWindow?.preventsApplicationTerminationWhenModal =
                allowsTerminationRequest ? false : originalPrevention
        }

        func detach() {
            attachedWindow?.preventsApplicationTerminationWhenModal = originalPrevention
            attachedWindow = nil
        }
    }
}
