import Foundation

/// The calendar event a recording overlapped, as `CalendarEventMatcher` found
/// it when the recording finished. Stored on the row
/// (`Recording.calendarEvent`) as a snapshot: it is not re-read from the
/// calendar later, so an event that is moved, renamed or deleted afterwards
/// leaves the recording describing the meeting as it was held.
///
/// Deliberately a plain value with no EventKit type in it. recordings.json is
/// a cross-process contract (MilaKit's `StoredRecording` mirrors this shape),
/// and an `EKEvent` identifier means nothing outside this Mac's calendar
/// database.
struct CalendarEventMatch: Codable, Hashable {
    /// One invited person. `email` is nil when the calendar account does not
    /// expose one (a contact-only invitee, some CalDAV servers).
    struct Attendee: Codable, Hashable {
        var name: String
        var email: String?

        init(name: String, email: String? = nil) {
            self.name = name
            self.email = email
        }

        private enum CodingKeys: String, CodingKey { case name, email }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            email = try c.decodeIfPresent(String.self, forKey: .email)
        }
    }

    var title: String
    var start: Date
    var end: Date
    /// Display name of the calendar the event lives in ("Work").
    var calendarName: String
    /// Human invitees only, the calendar's owner first when they are on the
    /// list — see `CalendarEventMatcher.humanAttendees`.
    var attendees: [Attendee]

    init(title: String, start: Date, end: Date, calendarName: String,
         attendees: [Attendee] = []) {
        self.title = title
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.attendees = attendees
    }

    private enum CodingKeys: String, CodingKey {
        case title, start, end, calendarName, attendees
    }

    /// Lenient on everything but the two dates: a match without its window
    /// says nothing, while a missing name or attendee list costs only detail.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        calendarName = try c.decodeIfPresent(String.self, forKey: .calendarName) ?? ""
        attendees = try c.decodeIfPresent([Attendee].self, forKey: .attendees) ?? []
    }

    /// `title` trimmed, or nil when it is blank. An untitled event is still a
    /// match worth storing, but it is not a recording title.
    var resolvedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
