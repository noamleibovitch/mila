import Foundation
import Combine

/// App-lifetime menu-bar model. Owned by `MilaAppDelegate` — not by the
/// transient menu content — so an in-flight Start/Stop task outlives the menu
/// closing. It is a leaf `ObservableObject`: only the status label and menu
/// content observe it, never the App's scene body.
@MainActor
final class MenuBarController: ObservableObject {
    /// Live wiring supplied once by `MilaApp`. Kept behind a tiny seam so the
    /// action bindings and failure recovery can be tested without an
    /// AVAudioEngine or a real main window.
    @MainActor
    struct Runtime {
        var input: @MainActor () -> MenuBarStatusInput
        var start: @MainActor (_ microphone: Bool, _ appAudio: Bool) async -> Void
        var stop: @MainActor () async -> Void
        /// True once an accepted start has actually claimed the job.
        var startBegan: @MainActor () -> Bool
        /// Any existing UI state that needs the main window on screen
        /// (errors, permission alerts, rename/import sheets).
        var blockingState: @MainActor () -> Bool
        /// Reveals the resident main window only if it is hidden/minimized.
        var revealIfHidden: @MainActor () -> Void
        /// Restores the registered main window; false when there is none.
        var restoreMainWindow: @MainActor () -> Bool
    }

    @Published private(set) var status: MenuBarStatus = .ready
    @Published private(set) var canStart = false
    @Published private(set) var canStop = false
    @Published private(set) var sourceCaption: String?
    @Published private(set) var isConfigured = false

    private var runtime: Runtime?
    private var settingsDefaults: UserDefaults
    private var observations: Set<AnyCancellable> = []
    private var defaultsObserver: NSObjectProtocol?
    private var actionInFlight = false
    /// Testable read-only view of the single-action guard. Kept out of the
    /// published surface so it never drives UI updates.
    var isPerformingAction: Bool { actionInFlight }
    private var lastBlockingState = false
    private var hasRefreshed = false

    init(settingsDefaults: UserDefaults = .standard) {
        self.settingsDefaults = settingsDefaults
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Wire the live dependencies and start observing only low-frequency
    /// state publishers. High-frequency transcription progress and the
    /// session meters are deliberately absent.
    func configure(runtime: Runtime,
                   changes: [AnyPublisher<Void, Never>] = []) {
        self.runtime = runtime
        isConfigured = true

        observations.removeAll()
        for change in changes {
            change
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refresh() }
                .store(in: &observations)
        }
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    /// Recompute the leaf's published state. Safe to call from any of the
    /// subscribed low-frequency publishers and from tests.
    func refresh() {
        guard let runtime else {
            status = .ready
            canStart = false
            canStop = false
            sourceCaption = nil
            return
        }
        let input = currentInput(runtime)
        status = MenuBarPolicy.status(for: input)
        canStart = MenuBarPolicy.canStart(input)
        canStop = MenuBarPolicy.canStop(input)
        sourceCaption = MenuBarPolicy.sourceCaption(for: input)

        let blocking = runtime.blockingState()
        if hasRefreshed && blocking && !lastBlockingState {
            runtime.revealIfHidden()
        }
        lastBlockingState = blocking
        hasRefreshed = true
    }

    var recordTitle: String {
        canStop ? "Stop Recording" : "Start Recording"
    }

    /// Fresh status for the first-close copy. Reads the live input directly so
    /// the explanation agrees with the recording even if the menu's published
    /// snapshot is a runloop turn behind.
    func currentStatus() -> MenuBarStatus {
        guard let runtime else { return .ready }
        return MenuBarPolicy.status(for: currentInput(runtime))
    }

    /// Preserve the intent captured with the displayed menu title. Revalidate
    /// against live state before execution; a stale Start or Stop must never
    /// turn into its opposite when another surface changes capture state.
    func performRecord(stopRequested: Bool) {
        guard let runtime, !actionInFlight else { return }
        let input = currentInput(runtime)

        if stopRequested {
            guard MenuBarPolicy.canStop(input) else { refresh(); return }
            actionInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishAction() }
                guard MenuBarPolicy.canStop(self.currentInput(runtime)) else { return }
                await runtime.stop()
            }
            return
        }

        guard MenuBarPolicy.canStart(input) else { refresh(); return }
        let sources = MenuBarSourceSettings.read(from: settingsDefaults)
        actionInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishAction() }
            // The Task can start a runloop turn after the menu click. Check
            // again before entering the shared toggle, which can also Stop.
            guard MenuBarPolicy.canStart(self.currentInput(runtime)) else { return }
            await runtime.start(sources.microphone, sources.appAudio)
            // A refused start with no error state must not leave the user
            // staring at a menu that silently did nothing. A permission/error
            // transition is revealed exactly once by `finishAction()`'s
            // blocking-state refresh instead (never twice).
            if !runtime.startBegan() && !runtime.blockingState() {
                runtime.revealIfHidden()
            }
        }
    }

    /// Menu "Open Mila". Returns false so the view can fall back to
    /// `openWindow(id:)` if the resident window was never registered.
    @discardableResult
    func openMainWindow() -> Bool {
        runtime?.restoreMainWindow() ?? false
    }

    private func finishAction() {
        actionInFlight = false
        refresh()
    }

    private func currentInput(_ runtime: Runtime) -> MenuBarStatusInput {
        var input = runtime.input()
        let sources = MenuBarSourceSettings.read(from: settingsDefaults)
        input.microphoneEnabled = sources.microphone
        input.appAudioEnabled = sources.appAudio
        return input
    }
}
