import Foundation
import Combine

/// User-facing toggle + per-app silencing for the meeting auto-prompt.
///
/// The prompt asks "Start transcribing?" when a meeting app (Zoom for
/// now — Google Meet / Teams are easy to add later) is detected in a live
/// meeting. Two pieces of state are persisted:
///
///   * `enabled` — global on/off. ON by default; the toggle lives in
///     Settings → Meetings.
///   * `disabledBundleIDs` — apps the user said "stop asking for this"
///     about, via the prompt's overflow chevron. Stored as a comma-
///     separated string in UserDefaults so it survives launches without
///     a custom Codable property list.
///
/// There used to be a 60-minute per-app *snooze* on dismiss — a workaround
/// for the old window-title detector that couldn't tell one meeting from
/// the next. `MeetingDetector` now re-arms reliably when a meeting ends
/// (mic capture stops), so "Not now" simply declines the current meeting
/// and the next one prompts again; no app-wide snooze is needed.
@MainActor
final class MeetingDetectionSettings: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published private(set) var disabledBundleIDs: Set<String> {
        didSet {
            let joined = disabledBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.disabledBundleIDs)
        }
    }
    /// Per-app auto-start overrides. Apps in this set auto-start
    /// regardless of the global toggle.
    @Published private(set) var autoStartBundleIDs: Set<String> {
        didSet {
            let joined = autoStartBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.autoStartApps)
        }
    }
    /// Per-app auto-stop overrides. Apps in this set auto-stop
    /// regardless of the global toggle.
    @Published private(set) var autoStopBundleIDs: Set<String> {
        didSet {
            let joined = autoStopBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.autoStopApps)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        self.enabled = defaults.bool(forKey: Keys.enabled)
        let raw = defaults.string(forKey: Keys.disabledBundleIDs) ?? ""
        self.disabledBundleIDs = Set(
            raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
        let autoStartRaw = defaults.string(forKey: Keys.autoStartApps) ?? ""
        self.autoStartBundleIDs = Set(
            autoStartRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
        let autoStopRaw = defaults.string(forKey: Keys.autoStopApps) ?? ""
        self.autoStopBundleIDs = Set(
            autoStopRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
    }

    func isDisabled(forBundleID bundleID: String) -> Bool {
        disabledBundleIDs.contains(bundleID)
    }

    /// Permanently silence the prompt for `bundleID`. Used by the
    /// "Don't show this for X" affordance inside the prompt overlay.
    func disable(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var copy = disabledBundleIDs
        copy.insert(bundleID)
        disabledBundleIDs = copy
    }

    /// Undo a silence — reverse of `disable(bundleID:)`. Surfaced from
    /// Settings → Meetings so the user can re-enable a previously-
    /// silenced app without digging into defaults.
    func reenable(bundleID: String) {
        var copy = disabledBundleIDs
        copy.remove(bundleID)
        disabledBundleIDs = copy
    }

    /// Whether auto-start should fire for a specific app. True if the
    /// per-app override is set, OR the global toggle is on and no
    /// per-app override exists.
    func shouldAutoStart(bundleID: String) -> Bool {
        autoStartBundleIDs.contains(bundleID)
    }

    func shouldAutoStop(bundleID: String) -> Bool {
        autoStopBundleIDs.contains(bundleID)
    }

    func setAutoStart(bundleID: String, enabled: Bool) {
        guard !bundleID.isEmpty else { return }
        var copy = autoStartBundleIDs
        if enabled { copy.insert(bundleID) } else { copy.remove(bundleID) }
        autoStartBundleIDs = copy
    }

    func setAutoStop(bundleID: String, enabled: Bool) {
        guard !bundleID.isEmpty else { return }
        var copy = autoStopBundleIDs
        if enabled { copy.insert(bundleID) } else { copy.remove(bundleID) }
        autoStopBundleIDs = copy
    }

    private enum Keys {
        static let enabled = "meetingDetection.enabled"
        static let autoStartApps = "meetingDetection.autoStartApps"
        static let autoStopApps = "meetingDetection.autoStopApps"
        static let disabledBundleIDs = "meetingDetection.disabledBundleIDs"
    }
}
