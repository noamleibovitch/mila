import AppKit

/// Resident controller for Mila's main window. The user-facing close button
/// hides the window with `orderOut` instead of destroying it, so the
/// ContentView's view-lifetime state (meeting detection, warm model, the
/// recording UI) survives while capture continues.
///
/// The window is held weakly; the controller never owns it. SwiftUI's
/// original `NSWindowDelegate` is preserved by a forwarding proxy, not
/// replaced wholesale, and is restored if registration is dismantled.
@MainActor
final class MenuBarWindowController: NSObject {
    typealias FirstClosePresenter = @MainActor (
        _ window: NSWindow,
        _ notice: MenuBarFirstCloseNotice,
        _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void

    private let defaults: UserDefaults
    private let presenter: FirstClosePresenter
    private let activate: @MainActor () -> Void

    private(set) weak var mainWindow: NSWindow?
    private var proxy: MenuBarWindowDelegateProxy?
    private var notificationTokens: [NSObjectProtocol] = []
    private var noticeInFlight = false
    private var isTerminating = false

    /// Supplies the state-aware copy for the first-close explanation. Wired
    /// by the app delegate to the menu model; weak to avoid a cycle.
    var statusProvider: (@MainActor () -> MenuBarStatus)?

    init(defaults: UserDefaults = .standard,
         presenter: FirstClosePresenter? = nil,
         activate: @escaping @MainActor () -> Void = {
             NSApp.activate(ignoringOtherApps: true)
         }) {
        self.defaults = defaults
        self.presenter = presenter ?? Self.presentNativeNotice
        self.activate = activate
        super.init()
    }

    /// Register the first (main) window only. A later window — Settings, a
    /// panel, or a secondary WindowGroup window — is left alone.
    func attach(window: NSWindow) {
        guard !isTerminating else { return }
        if let existing = mainWindow {
            if existing === window {
                reassertDelegate(on: window)
            }
            return
        }
        mainWindow = window
        installDelegate(on: window)
        observeDelegateReplacement(on: window)
        // SwiftUI can still be configuring the window on the first
        // `viewDidMoveToWindow`; re-check after this runloop turn too, so a
        // delegate installed later is wrapped rather than silently replacing
        // the close interception.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.reassertDelegate(on: window)
        }
    }

    /// Stop forwarding and put SwiftUI's original delegate back if it is
    /// still the one we wrapped.
    func detach(window: NSWindow) {
        guard window === mainWindow else { return }
        if (window.delegate as AnyObject?) === proxy {
            window.delegate = proxy?.original
        }
        removeObservers()
        proxy = nil
        mainWindow = nil
        noticeInFlight = false
    }

    /// Quit must be allowed to close the window without the background
    /// explanation or the close interception.
    func beginTermination() {
        isTerminating = true
    }

    /// Bring the resident window forward without creating a new one. A
    /// minimized window is deminiaturized first, then made key and front.
    @discardableResult
    func restoreMainWindow() -> Bool {
        guard let window = mainWindow else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        activate()
        return true
    }

    /// Reveal only when the window is not already usable. Background errors
    /// and permission alerts must be reachable without stealing focus from a
    /// visible window the user is already using.
    func revealIfHidden() {
        guard let window = mainWindow else { return }
        guard !window.isVisible || window.isMiniaturized else { return }
        restoreMainWindow()
    }

    // MARK: - Close interception

    func handleShouldClose(_ window: NSWindow) -> Bool {
        guard window === mainWindow else { return true }
        guard !isTerminating else { return true }
        // A repeated close while the explanation is up is a no-op.
        guard !noticeInFlight else { return false }

        let store = MenuBarFirstCloseStore(defaults: defaults)
        if store.hasExplained {
            hide(window)
            return false
        }

        noticeInFlight = true
        let status = statusProvider?() ?? .ready
        presenter(window, MenuBarFirstCloseNotice.forStatus(status)) { [weak self, weak window] acknowledged in
            guard let self else { return }
            self.noticeInFlight = false
            guard acknowledged, let window else { return }
            // Persist only after acknowledgement, then hide. The recording,
            // if any, has been running behind the sheet the whole time.
            store.markExplained()
            self.hide(window)
        }
        return false
    }

    private func hide(_ window: NSWindow) {
        window.orderOut(nil)
    }

    // MARK: - Delegate forwarding

    private func installDelegate(on window: NSWindow) {
        if (window.delegate as AnyObject?) === proxy { return }
        let forwarding = proxy ?? MenuBarWindowDelegateProxy(controller: self)
        forwarding.original = window.delegate
        proxy = forwarding
        window.delegate = forwarding
    }

    /// SwiftUI can reapply its own delegate. Re-wrap whatever it installed
    /// (rather than discarding it) when the window becomes key/main again.
    private func reassertDelegate(on window: NSWindow) {
        guard !isTerminating, window === mainWindow else { return }
        if (window.delegate as AnyObject?) === proxy { return }
        installDelegate(on: window)
    }

    private func observeDelegateReplacement(on window: NSWindow) {
        removeObservers()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let self, let window else { return }
                    self.reassertDelegate(on: window)
                }
            }
            notificationTokens.append(token)
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for token in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
    }

    static func presentNativeNotice(
        _ window: NSWindow,
        _ notice: MenuBarFirstCloseNotice,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.beginSheetModal(for: window) { _ in
            Task { @MainActor in completion(true) }
        }
    }
}

/// A transparent forwarding delegate. It intercepts only the user close; every
/// other optional `NSWindowDelegate` method is forwarded to the delegate
/// SwiftUI installed, so its behaviour is preserved rather than replaced.
@MainActor
final class MenuBarWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var controller: MenuBarWindowController?

    /// Strong on purpose: `NSWindow.delegate` is a weak reference, and this
    /// proxy is the object the window now points at. The original delegate
    /// cannot own the proxy or the window, so this is not a cycle.
    var original: (any NSWindowDelegate)?

    init(controller: MenuBarWindowController) {
        self.controller = controller
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Preserve SwiftUI's own answer when it has one (it can veto a close
        // for state it owns); interception only decides what happens after
        // the close is allowed.
        if let original,
           original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           original.windowShouldClose?(sender) == false {
            return false
        }
        return controller?.handleShouldClose(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }
}
