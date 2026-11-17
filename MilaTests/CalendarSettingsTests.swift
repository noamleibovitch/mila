import Combine
import XCTest
@testable import Mila

/// A calendar database for tests: fixed calendars and events, a scripted
/// answer to the permission prompt, and counters for what was asked of it.
/// Nothing in the suite may construct `EventKitCalendarProvider` — that
/// would read the developer's real calendars and can raise a system prompt.
@MainActor
final class FakeCalendarProvider: CalendarEventProviding {
    var authorization: CalendarAuthorization
    /// What the user answers when asked. Applied by `requestAccess()`.
    var grantOnRequest = true
    var allCalendars: [CalendarInfo]
    var allEvents: [CalendarEventCandidate]
    var beforeEvents: (() async -> Void)?

    private(set) var accessRequests = 0
    private(set) var calendarListReads = 0
    private(set) var eventQueries: [(interval: DateInterval, calendarIDs: Set<String>)] = []

    init(authorization: CalendarAuthorization = .notDetermined,
         calendars: [CalendarInfo] = [],
         events: [CalendarEventCandidate] = []) {
        self.authorization = authorization
        self.allCalendars = calendars
        self.allEvents = events
    }

    func requestAccess() async -> Bool {
        accessRequests += 1
        if authorization == .notDetermined {
            authorization = grantOnRequest ? .fullAccess : .denied
        }
        return authorization == .fullAccess
    }

    func calendars() -> [CalendarInfo] {
        calendarListReads += 1
        return authorization == .fullAccess ? allCalendars : []
    }

    func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [CalendarEventCandidate] {
        eventQueries.append((interval, calendarIDs))
        await beforeEvents?()
        guard authorization == .fullAccess else { return [] }
        // Deliberately NOT filtered by `calendarIDs`: the matcher has to
        // enforce the allow-list itself, whatever a provider hands back.
        return allEvents.filter { $0.end > interval.start && $0.start < interval.end }
    }
}

@MainActor
final class CalendarSettingsTests: XCTestCase {

    private let suite = "CalendarSettingsTests.calendar"
    private var defaults: UserDefaults!
    private var provider: FakeCalendarProvider!

    private let work = CalendarInfo(id: "cal-work", title: "Work", sourceTitle: "Google")
    private let home = CalendarInfo(id: "cal-home", title: "Home", sourceTitle: "iCloud")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)!
        provider = FakeCalendarProvider(calendars: [work, home])
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func makeSettings() -> CalendarSettings {
        CalendarSettings(defaults: defaults, provider: provider)
    }

    // MARK: - Defaults

    func test_fresh_install_is_off_and_touches_nothing() {
        let settings = makeSettings()
        settings.refresh()
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.allowedCalendarIDs.isEmpty)
        XCTAssertFalse(settings.isReady)
        XCTAssertEqual(provider.accessRequests, 0, "no prompt until the user turns it on")
        XCTAssertEqual(provider.calendarListReads, 0, "no calendar read while it is off")
        XCTAssertTrue(settings.calendars.isEmpty)
    }

    // MARK: - Permission

    func test_turning_on_asks_for_access_once_and_lists_calendars() async {
        let settings = makeSettings()
        await settings.setEnabled(true)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(provider.accessRequests, 1)
        XCTAssertEqual(settings.authorization, .fullAccess)
        XCTAssertEqual(settings.calendars, [work, home])

        await settings.setEnabled(false)
        await settings.setEnabled(true)
        XCTAssertEqual(provider.accessRequests, 1, "already decided — nothing to ask")
    }

    func test_refused_access_leaves_the_switch_on_but_not_ready() async {
        provider.grantOnRequest = false
        let settings = makeSettings()
        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: true)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.authorization, .denied)
        XCTAssertFalse(settings.isReady)
        XCTAssertTrue(settings.calendars.isEmpty)
    }

    func test_turning_off_does_not_ask_for_access() async {
        let settings = makeSettings()
        await settings.setEnabled(false)
        XCTAssertEqual(provider.accessRequests, 0)
    }

    // MARK: - isReady: enabled AND access AND a calendar

    func test_isReady_needs_all_three() async {
        let settings = makeSettings()
        await settings.setEnabled(true)
        XCTAssertFalse(settings.isReady, "access but no calendar ticked")

        settings.setCalendar(work.id, allowed: true)
        XCTAssertTrue(settings.isReady)

        await settings.setEnabled(false)
        XCTAssertFalse(settings.isReady, "calendar and access, switched off")

        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: false)
        XCTAssertFalse(settings.isReady, "last calendar unticked")
    }

    /// Access can be taken away in System Settings while Mila runs, with no
    /// `refresh()` in between. `isReady` must already say no.
    func test_isReady_follows_access_revoked_behind_its_back() async {
        let settings = makeSettings()
        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: true)
        XCTAssertTrue(settings.isReady)

        provider.authorization = .denied
        XCTAssertFalse(settings.isReady)
        XCTAssertEqual(settings.authorization, .fullAccess, "the displayed state is as of the last refresh")
        settings.refresh()
        XCTAssertEqual(settings.authorization, .denied)
        XCTAssertTrue(settings.calendars.isEmpty)
    }

    // MARK: - Persistence

    func test_choices_persist_under_namespaced_keys_and_reload() async {
        let settings = makeSettings()
        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: true)
        settings.setCalendar(home.id, allowed: true)
        settings.setCalendar(home.id, allowed: false)

        XCTAssertEqual(defaults.object(forKey: "calendar.enabled") as? Bool, true)
        XCTAssertEqual(defaults.stringArray(forKey: "calendar.allowedCalendarIDs"), ["cal-work"])

        let relaunched = makeSettings()
        XCTAssertTrue(relaunched.enabled)
        XCTAssertEqual(relaunched.allowedCalendarIDs, ["cal-work"])
        XCTAssertTrue(relaunched.isReady, "restored without asking or refreshing")
        XCTAssertEqual(provider.accessRequests, 1)
    }

    func test_unchanged_calendar_choice_publishes_nothing() async {
        let settings = makeSettings()
        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: true)
        var publishes = 0
        let observation = settings.objectWillChange.sink { publishes += 1 }
        settings.setCalendar(work.id, allowed: true)
        settings.setCalendar(home.id, allowed: false)
        settings.refresh()
        XCTAssertEqual(publishes, 0)
        observation.cancel()
    }

    // MARK: - Lookup

    private func recording(endingAt end: Date, minutes: Double) -> Recording {
        Recording(title: "Meeting", createdAt: end, duration: minutes * 60,
                  source: .meeting, audioFileName: "m.wav")
    }

    func test_lookup_matches_through_the_gate_and_queries_only_the_recording_window() async {
        let end = Date(timeIntervalSince1970: 1_700_001_800)
        let start = end.addingTimeInterval(-1800)
        provider.allEvents = [
            CalendarEventCandidate(title: "Weekly sync", start: start, end: end,
                                   calendarID: work.id, calendarName: "Work"),
            CalendarEventCandidate(title: "Private", start: start, end: end.addingTimeInterval(3600),
                                   calendarID: home.id, calendarName: "Home"),
        ]
        let settings = makeSettings()
        let lookup = CalendarEventLookup(settings: settings)

        XCTAssertFalse(lookup.isReady)
        let disabledMatch = await lookup.match(for: recording(endingAt: end, minutes: 30))
        XCTAssertNil(disabledMatch)
        XCTAssertTrue(provider.eventQueries.isEmpty, "not ready: the calendar is not read at all")

        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: true)
        let found = await lookup.match(for: recording(endingAt: end, minutes: 30))
        XCTAssertEqual(found?.title, "Weekly sync",
                       "the unticked calendar's event is ignored even though the provider returned it")
        XCTAssertEqual(provider.eventQueries.count, 1)
        XCTAssertEqual(provider.eventQueries.first?.interval, DateInterval(start: start, end: end))
        XCTAssertEqual(provider.eventQueries.first?.calendarIDs, [work.id])
    }

    func test_lookup_of_a_zero_length_recording_reads_nothing() async {
        let settings = makeSettings()
        await settings.setEnabled(true)
        settings.setCalendar(work.id, allowed: true)
        let lookup = CalendarEventLookup(settings: settings)
        let emptyMatch = await lookup.match(for: recording(endingAt: Date(), minutes: 0))
        XCTAssertNil(emptyMatch)
        XCTAssertTrue(provider.eventQueries.isEmpty)
    }
}
