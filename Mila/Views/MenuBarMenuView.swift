import SwiftUI
import AppKit

/// The menu-bar icon. It observes the leaf model directly so a state change
/// re-renders the status item, not the App's scene body.
struct MenuBarStatusLabel: View {
    @ObservedObject var controller: MenuBarController

    var body: some View {
        Image(systemName: controller.status.symbolName)
            .accessibilityLabel(controller.status.accessibilityLabel)
            .help(controller.status.accessibilityLabel)
    }
}

/// Native `.menu`-style MenuBarExtra content. Deliberately no second engine or
/// actions object: every command routes to the existing app controller.
struct MenuBarMenuView: View {
    @ObservedObject var controller: MenuBarController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.status.accessibilityLabel)
            .accessibilityIdentifier("menuBar.status")

        if let caption = controller.sourceCaption {
            Text(caption)
                .accessibilityIdentifier("menuBar.source")
        }

        Divider()

        Button(controller.recordTitle) {
            controller.performRecord()
        }
        .disabled(!controller.canStop && !controller.canStart)
        .accessibilityIdentifier("menuBar.record")

        Button("Open Mila") {
            if !controller.openMainWindow() {
                openWindow(id: "main")
            }
        }
        .accessibilityIdentifier("menuBar.open")

        // Native Settings presentation. SettingsLink is the supported entry
        // point and brings the Settings scene forward itself; closing that
        // window keeps its normal close behaviour because only the main
        // window is registered with the resident controller.
        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .accessibilityIdentifier("menuBar.settings")

        Divider()

        Button("Quit Mila") {
            NSApp.terminate(nil)
        }
        .help("Quit Mila — stops any active recording and exits.")
        .accessibilityIdentifier("menuBar.quit")
    }
}
