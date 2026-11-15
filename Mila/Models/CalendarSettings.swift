import Combine
import Foundation

/// Settings → Meetings → "Match recordings to calendar events": whether Mila
/// reads the user's calendar, and which calendars it may read.
///
/// Off by default, and opt-in twice. Turning the feature on is what raises
/// the system's calendar permission prompt (never launch, never opening
/// Settings), and after that no calendar is read until the user ticks it:
/// a shared team calendar or a partner's calendar sits next to the user's own
/// in the same account, and "allowed" must not mean "everything Calendar.app
/// can see".
///
/// `isReady` is the gate every reader uses — enabled AND access granted AND
/// at least one calendar ticked (`.claude/rules/feature-gates.md`).
@MainActor
final class CalendarSettings: ObservableObject {

    /// The user's switch. Persisted on change. Flip it through
    /// `setEnabled(_:)`, which also asks for calendar access.
    @Published private(set) var enabled: Bool

    /// `CalendarInfo.id`s of the calendars Mila may read. An id whose
    /// calendar has since been removed stays in the set and matches nothing.
    @Published private(set) var allowedCalendarIDs: Set<String>

    /// Calendar access as of the last `refresh()`. For display — `isReady`
    /// asks the provider directly, because access can be revoked in System
    /// Settings while Mila is running.
    @Published private(set) var authorization: CalendarAuthorization

    /// The calendars to offer in Settings, as of the last `refresh()`. Empty
    /// without access.
    @Published private(set) var calendars: [CalendarInfo] = []

    let provider: CalendarEventProviding
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         provider: CalendarEventProviding? = nil) {
        self.defaults = defaults
        // Built here, not as a default argument: a default is evaluated in
        // the caller's context, which need not be the main actor.
        let provider = provider ?? EventKitCalendarProvider()
        self.provider = provider
        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.allowedCalendarIDs = Set(defaults.stringArray(forKey: Keys.allowedCalendarIDs) ?? [])
        self.authorization = provider.authorization
    }

    /// Enabled AND ready to use: the switch is on, the system grants full
    /// access right now, and at least one calendar is ticked.
    var isReady: Bool {
        enabled && provider.authorization == .fullAccess && !allowedCalendarIDs.isEmpty
    }

    /// Turn the feature on or off. Turning it on asks for calendar access if
    /// the system has never been asked; a refusal leaves the switch on with
    /// `isReady` false, and Settings says why.
    func setEnabled(_ newValue: Bool) async {
        if enabled != newValue {
            enabled = newValue
            defaults.set(newValue, forKey: Keys.enabled)
        }
        if newValue, provider.authorization == .notDetermined {
            _ = await provider.requestAccess()
        }
        refresh()
    }

    func setCalendar(_ id: String, allowed: Bool) {
        var ids = allowedCalendarIDs
        if allowed { ids.insert(id) } else { ids.remove(id) }
        guard ids != allowedCalendarIDs else { return }
        allowedCalendarIDs = ids
        defaults.set(ids.sorted(), forKey: Keys.allowedCalendarIDs)
    }

    /// Re-read access and the calendar list from the system. Called when
    /// Settings shows the section and after a permission request. Reads no
    /// calendar while the feature is off.
    func refresh() {
        let current = provider.authorization
        if authorization != current { authorization = current }
        let listed = enabled ? provider.calendars() : []
        if calendars != listed { calendars = listed }
    }

    enum Keys {
        static let enabled = "calendar.enabled"
        static let allowedCalendarIDs = "calendar.allowedCalendarIDs"
    }
}
