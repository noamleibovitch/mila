import XCTest
@testable import Mila

/// The rules that decide which calendar event a recording belongs to.
/// `CalendarEventMatcher` is pure, so every case here is a hand-built window
/// and candidate list — no EventKit, no clock.
final class CalendarEventMatcherTests: XCTestCase {

    private let work = "cal-work"
    /// 10:00 on an arbitrary day; every time below is minutes from it.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func window(_ start: Double, _ end: Double) -> DateInterval {
        DateInterval(start: at(start), end: at(end))
    }

    private func event(_ title: String, _ start: Double, _ end: Double,
                       calendar: String? = nil,
                       allDay: Bool = false,
                       declined: Bool = false,
                       canceled: Bool = false,
                       attendees: [CalendarEventCandidate.Attendee] = []) -> CalendarEventCandidate {
        CalendarEventCandidate(title: title, start: at(start), end: at(end), isAllDay: allDay,
                               calendarID: calendar ?? work, calendarName: "Work",
                               attendees: attendees, isDeclined: declined, isCanceled: canceled)
    }

    private func match(_ window: DateInterval,
                       _ events: [CalendarEventCandidate],
                       allowed: Set<String>? = nil) -> CalendarEventMatch? {
        CalendarEventMatcher.bestMatch(window: window, candidates: events,
                                       allowedCalendarIDs: allowed ?? [work])
    }

    // MARK: - At recording start

    private func current(_ minute: Double, _ events: [CalendarEventCandidate]) -> String? {
        CalendarEventMatcher.currentEvent(at: at(minute), candidates: events,
                                          allowedCalendarIDs: [work])?.title
    }

    func test_start_inside_an_event_takes_it() {
        XCTAssertEqual(current(10, [event("Sync", 0, 30)]), "Sync")
    }

    func test_start_a_few_minutes_early_takes_the_event_about_to_begin() {
        XCTAssertEqual(current(-4, [event("Sync", 0, 30)]), "Sync")
        XCTAssertNil(current(-11, [event("Sync", 0, 30)]))
    }

    func test_start_after_an_event_ended_is_nil() {
        XCTAssertNil(current(30, [event("Sync", 0, 30)]))
    }

    func test_start_in_the_last_minutes_of_one_event_takes_the_next() {
        let events = [event("First", 0, 30), event("Second", 30, 60)]
        XCTAssertEqual(current(27, events), "Second")
        XCTAssertEqual(current(20, events), "First")
    }

    func test_start_inside_two_events_takes_the_one_that_began_last() {
        XCTAssertEqual(current(40, [event("Block", 0, 120), event("1:1", 30, 60)]), "1:1")
    }

    func test_start_ignores_events_the_overlap_match_ignores() {
        XCTAssertNil(current(10, [event("Off list", 0, 30, calendar: "cal-home"),
                                  event("All day", 0, 30, allDay: true),
                                  event("Declined", 0, 30, declined: true),
                                  event("Canceled", 0, 30, canceled: true)]))
    }

    // MARK: - Recording window

    /// `createdAt` is the STOP time, so the window runs backwards from it.
    func test_window_ends_at_createdAt_and_starts_a_duration_earlier() {
        let w = CalendarEventMatcher.recordingWindow(createdAt: at(30), duration: 30 * 60)
        XCTAssertEqual(w.start, at(0))
        XCTAssertEqual(w.end, at(30))
    }

    func test_window_of_a_nonsense_duration_is_empty_and_matches_nothing() {
        for duration in [0, -5, Double.nan, Double.infinity] {
            let w = CalendarEventMatcher.recordingWindow(createdAt: at(30), duration: duration)
            XCTAssertEqual(w.duration, 0, "\(duration)")
            XCTAssertNil(match(w, [event("Sync", 0, 60)]), "\(duration)")
        }
    }

    // MARK: - Which event

    func test_event_the_recording_sits_inside_matches_with_its_details() {
        let found = match(window(2, 28), [event("Weekly sync", 0, 30)])
        XCTAssertEqual(found?.title, "Weekly sync")
        XCTAssertEqual(found?.start, at(0))
        XCTAssertEqual(found?.end, at(30))
        XCTAssertEqual(found?.calendarName, "Work")
    }

    func test_no_events_is_nil() {
        XCTAssertNil(match(window(0, 30), []))
    }

    func test_event_that_does_not_overlap_is_nil() {
        XCTAssertNil(match(window(0, 30), [event("Later", 30, 60)]),
                     "touching end-to-start shares no time")
        XCTAssertNil(match(window(0, 30), [event("Earlier", -60, -10)]))
    }

    func test_largest_absolute_overlap_wins() {
        // Recording 0–60. "Short" is wholly inside it (20 min); "Long" covers
        // 35 minutes of it. Coverage of the EVENT is irrelevant: Long wins.
        let found = match(window(0, 60), [event("Short", 0, 20), event("Long", 25, 120)])
        XCTAssertEqual(found?.title, "Long")
    }

    func test_result_does_not_depend_on_candidate_order() {
        let a = event("Short", 0, 20)
        let b = event("Long", 25, 120)
        XCTAssertEqual(match(window(0, 60), [a, b]), match(window(0, 60), [b, a]))
    }

    func test_equal_overlap_goes_to_the_event_starting_nearer_the_recording() {
        // Both cover the whole 10–40 recording.
        let near = event("Near", 10, 40)
        let far = event("Far", 0, 60)
        XCTAssertEqual(match(window(10, 40), [far, near])?.title, "Near")
        XCTAssertEqual(match(window(10, 40), [near, far])?.title, "Near")
    }

    func test_identical_events_tie_break_on_title() {
        let a = event("Alpha", 0, 30)
        let b = event("Beta", 0, 30)
        XCTAssertEqual(match(window(0, 30), [b, a])?.title, "Alpha")
        XCTAssertEqual(match(window(0, 30), [a, b])?.title, "Alpha")
    }

    /// Overlap, distance and title all equal: the order is still total, so
    /// EventKit handing the events back in another order changes nothing.
    func test_events_equal_in_overlap_distance_and_title_still_resolve_one_way() {
        let allowed: Set<String> = ["cal-a", "cal-b"]
        // Same title and same overlap of the 10–40 recording, starting 5
        // minutes either side of its start.
        let earlier = event("Sync", 5, 40, calendar: "cal-b")
        let later = event("Sync", 15, 45, calendar: "cal-a")
        XCTAssertEqual(match(window(10, 45), [earlier, later], allowed: allowed)?.start, at(5))
        XCTAssertEqual(match(window(10, 45), [later, earlier], allowed: allowed)?.start, at(5),
                       "the earlier start wins whichever comes first")

        // Identical but for the calendar they are in.
        var inA = event("Sync", 0, 30, calendar: "cal-a")
        inA.calendarName = "A"
        var inB = event("Sync", 0, 30, calendar: "cal-b")
        inB.calendarName = "B"
        XCTAssertEqual(match(window(0, 30), [inA, inB], allowed: allowed)?.calendarName, "A")
        XCTAssertEqual(match(window(0, 30), [inB, inA], allowed: allowed)?.calendarName, "A")

        // Same start, different end, same overlap inside the recording.
        let short = event("Sync", 0, 40, calendar: "cal-a")
        let long = event("Sync", 0, 90, calendar: "cal-a")
        XCTAssertEqual(match(window(0, 30), [long, short], allowed: allowed)?.end, at(40))
        XCTAssertEqual(match(window(0, 30), [short, long], allowed: allowed)?.end, at(40))
    }

    // MARK: - Minimum overlap

    /// A long recording needs five minutes, not 20% of itself.
    func test_long_recording_needs_five_minutes_of_overlap() {
        let recording = window(0, 120)          // 20% would be 24 minutes
        XCTAssertNil(match(recording, [event("Clipped", 116, 180)]), "4 minutes")
        XCTAssertEqual(match(recording, [event("Enough", 115, 180)])?.title, "Enough",
                       "exactly 5 minutes qualifies")
    }

    /// A short recording needs 20% of itself, not five minutes it never had.
    func test_short_recording_needs_a_fifth_of_its_length() {
        let recording = window(0, 10)           // threshold 2 minutes
        XCTAssertNil(match(recording, [event("Clipped", 9, 40)]), "1 minute")
        XCTAssertEqual(match(recording, [event("Enough", 8, 40)])?.title, "Enough",
                       "exactly 2 minutes qualifies")
        XCTAssertEqual(match(window(0, 3), [event("Stand-up", 0, 15)])?.title, "Stand-up",
                       "a 3-minute recording can match at all")
    }

    func test_event_below_the_threshold_is_not_a_fallback_when_it_is_the_only_one() {
        XCTAssertNil(match(window(0, 60), [event("Next meeting", 58, 90)]),
                     "no match means nil, never the nearest event")
    }

    // MARK: - What is never considered

    func test_calendar_that_is_not_allowed_is_ignored() {
        let personal = event("Dentist", 0, 30, calendar: "cal-personal")
        XCTAssertNil(match(window(0, 30), [personal]))
        XCTAssertEqual(match(window(0, 30), [personal], allowed: ["cal-personal"])?.title, "Dentist")
        XCTAssertNil(match(window(0, 30), [event("Sync", 0, 30)], allowed: []),
                     "nothing allowed, nothing matched")
    }

    func test_allowed_event_wins_over_a_bigger_overlap_in_another_calendar() {
        let found = match(window(0, 60), [event("Private", 0, 60, calendar: "cal-personal"),
                                          event("Sync", 0, 20)])
        XCTAssertEqual(found?.title, "Sync")
    }

    func test_all_day_event_is_skipped() {
        XCTAssertNil(match(window(0, 30), [event("Out of office", -600, 840, allDay: true)]))
        let found = match(window(0, 30), [event("Out of office", -600, 840, allDay: true),
                                          event("Sync", 5, 30)])
        XCTAssertEqual(found?.title, "Sync", "the all-day event's larger overlap does not count")
    }

    func test_declined_and_cancelled_events_are_skipped() {
        XCTAssertNil(match(window(0, 30), [event("Declined", 0, 30, declined: true)]))
        XCTAssertNil(match(window(0, 30), [event("Cancelled", 0, 30, canceled: true)]))
        let found = match(window(0, 30), [event("Declined", 0, 30, declined: true),
                                          event("Attended", 10, 30)])
        XCTAssertEqual(found?.title, "Attended")
    }

    func test_event_with_an_inverted_or_empty_span_is_skipped() {
        XCTAssertNil(match(window(0, 30), [event("Broken", 20, 10), event("Instant", 10, 10)]))
    }

    func test_untitled_event_still_matches_but_offers_no_title() {
        let found = match(window(0, 30), [event("   ", 0, 30)])
        XCTAssertNotNil(found)
        XCTAssertNil(found?.resolvedTitle)
        XCTAssertEqual(match(window(0, 30), [event(" Sync \n", 0, 30)])?.resolvedTitle, "Sync")
    }

    // MARK: - Attendees

    private func person(_ name: String, _ email: String? = nil,
                        kind: CalendarEventCandidate.AttendeeKind = .person,
                        me: Bool = false) -> CalendarEventCandidate.Attendee {
        .init(name: name, email: email, kind: kind, isCurrentUser: me)
    }

    func test_rooms_resources_and_groups_are_dropped() {
        let kept = CalendarEventMatcher.humanAttendees([
            person("Dana", "dana@example.com"),
            person("Board Room", "room1@example.com", kind: .room),
            person("Projector", "projector@example.com", kind: .resource),
            person("Engineering", "eng@example.com", kind: .group),
            person("Odd one", "odd@example.com", kind: .unknown),
        ])
        XCTAssertEqual(kept.map(\.name), ["Dana", "Odd one"],
                       "an invitee of unknown kind is kept — it may well be a person")
    }

    func test_bot_and_list_addresses_are_dropped() {
        let automated = [
            "noreply@example.com", "no-reply@example.com", "NoReply+abc@example.com",
            "donotreply@example.com", "do-not-reply@example.com",
            "calendar-notification@google.com", "notifications@example.com",
            "standup-bot@example.com", "bot@example.com", "meeting.bot@example.com",
            "notetaker@example.com", "mailer-daemon@example.com",
            "c_188abc@resource.calendar.google.com", "team@group.calendar.google.com",
        ]
        for email in automated {
            XCTAssertTrue(CalendarEventMatcher.isAutomatedAddress(email), email)
        }
        let human = [
            "dana@example.com", "abbot@example.com", "robotnik@example.com",
            "talbot.smith@example.com", "reply@example.com", "not-an-email",
        ]
        for email in human {
            XCTAssertFalse(CalendarEventMatcher.isAutomatedAddress(email), email)
        }
        let kept = CalendarEventMatcher.humanAttendees([
            person("Notifier", "noreply@example.com"),
            person("Dana", "dana@example.com"),
        ])
        XCTAssertEqual(kept, [.init(name: "Dana", email: "dana@example.com")])
    }

    func test_calendar_owner_is_listed_first_and_the_rest_keep_their_order() {
        let kept = CalendarEventMatcher.humanAttendees([
            person("Dana", "dana@example.com"),
            person("Uri", "uri@example.com"),
            person("Me", "me@example.com", me: true),
            person("Noa", "noa@example.com"),
        ])
        XCTAssertEqual(kept.map(\.name), ["Me", "Dana", "Uri", "Noa"])
    }

    func test_owner_absent_from_the_list_changes_nothing() {
        let kept = CalendarEventMatcher.humanAttendees([person("Dana"), person("Uri")])
        XCTAssertEqual(kept.map(\.name), ["Dana", "Uri"])
    }

    func test_same_address_twice_is_one_attendee_and_blank_names_fall_back_to_the_address() {
        let kept = CalendarEventMatcher.humanAttendees([
            person("Dana", "Dana@Example.com"),
            person("Dana (again)", "dana@example.com"),
            person("  ", "uri@example.com"),
            person("", nil),
            person("No Mail", "  "),
        ])
        XCTAssertEqual(kept, [.init(name: "Dana", email: "Dana@Example.com"),
                              .init(name: "uri@example.com", email: "uri@example.com"),
                              .init(name: "No Mail", email: nil)])
    }

    func test_match_carries_the_filtered_attendees() {
        let found = match(window(0, 30), [event("Sync", 0, 30, attendees: [
            person("Dana", "dana@example.com"),
            person("Room 4", "room4@example.com", kind: .room),
            person("Me", "me@example.com", me: true),
        ])])
        XCTAssertEqual(found?.attendees.map(\.name), ["Me", "Dana"])
    }
}
