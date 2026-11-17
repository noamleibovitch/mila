import Foundation

/// One calendar event as the matcher sees it: everything `CalendarEventMatcher`
/// needs and nothing from EventKit, so the matching rules are tested with
/// hand-built values and any other source of events can feed them.
struct CalendarEventCandidate: Hashable {
    /// What kind of thing an invitee is. Rooms and equipment are invited like
    /// people, and a distribution list is one invitee standing for many.
    enum AttendeeKind: Hashable {
        case person, room, resource, group, unknown
    }

    struct Attendee: Hashable {
        var name: String
        var email: String?
        var kind: AttendeeKind = .person
        /// The calendar account's own user.
        var isCurrentUser: Bool = false
    }

    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var calendarID: String
    var calendarName: String
    var attendees: [Attendee] = []
    /// The user answered "no" to this invitation.
    var isDeclined: Bool = false
    /// The organiser cancelled the event but it is still on the calendar.
    var isCanceled: Bool = false
}

/// Picks the calendar event a recording belongs to. Pure: the same window and
/// candidates always give the same answer, and nothing here reads a calendar.
///
/// The rule it protects is "no match means nil, never a guess". The match
/// becomes the recording's title, so a wrong one names a recording after a
/// meeting it was not — worse than leaving the title to the fallback.
enum CalendarEventMatcher {

    /// A recording has to share at least this much time with an event…
    static let minimumOverlap: TimeInterval = 5 * 60
    /// …or this fraction of its own length, whichever is smaller, so a
    /// three-minute stand-up can match while a two-hour recording does not
    /// take the name of an event it clipped for a minute.
    static let minimumOverlapFraction = 0.2

    /// The window a recording covers. `Recording.createdAt` is stamped when
    /// the recording STOPS (`QuickActionsController.stopRecording` builds the
    /// row then, with the default `createdAt: Date()`), so the recording ran
    /// from `createdAt - duration` to `createdAt`.
    static func recordingWindow(createdAt: Date, duration: TimeInterval) -> DateInterval {
        let length = duration.isFinite ? max(0, duration) : 0
        return DateInterval(start: createdAt.addingTimeInterval(-length), duration: length)
    }

    /// The event `window` overlaps most, or nil when none qualifies.
    ///
    /// Considered: timed events in `allowedCalendarIDs` that the user did not
    /// decline and nobody cancelled. The largest absolute overlap wins, and it
    /// must reach `min(minimumOverlap, minimumOverlapFraction × window)`. Two
    /// events with the same overlap go to the one starting nearer the
    /// recording's start, then to the earlier title, start, end and calendar
    /// id (`isBetter`), so the answer never depends on the order the
    /// calendar returned them in.
    static func bestMatch(window: DateInterval,
                          candidates: [CalendarEventCandidate],
                          allowedCalendarIDs: Set<String>) -> CalendarEventMatch? {
        guard window.duration > 0 else { return nil }
        let required = min(minimumOverlap, minimumOverlapFraction * window.duration)

        var best: (event: CalendarEventCandidate, overlap: TimeInterval)?
        for event in candidates {
            guard allowedCalendarIDs.contains(event.calendarID),
                  !event.isAllDay, !event.isDeclined, !event.isCanceled,
                  event.end > event.start else { continue }
            let overlap = min(window.end, event.end)
                .timeIntervalSince(max(window.start, event.start))
            // A millisecond of slack: `required` is a product of doubles, and
            // an overlap of exactly the threshold must not lose to rounding.
            guard overlap > 0, overlap + 0.001 >= required else { continue }
            if let current = best, !isBetter(event, overlap, than: current, window: window) {
                continue
            }
            best = (event, overlap)
        }
        guard let event = best?.event else { return nil }
        return CalendarEventMatch(title: event.title,
                                  start: event.start,
                                  end: event.end,
                                  calendarName: event.calendarName,
                                  attendees: humanAttendees(event.attendees))
    }

    // MARK: - At recording start

    /// How far ahead of an event's start a recording may begin and still be
    /// taken for it: joining a call a few minutes early.
    static let startLead: TimeInterval = 10 * 60
    /// An event with less than this left to run loses to one about to start:
    /// pressing Record in the last minutes of a meeting is the next meeting.
    static let endingSoon: TimeInterval = 5 * 60

    /// The event a recording that starts at `now` is most likely for, or nil.
    ///
    /// A guess, unlike `bestMatch`: nothing has been recorded yet, so there
    /// is no overlap to measure. It is shown while recording and never
    /// stored; `bestMatch` on the finished recording decides the title.
    ///
    /// Same events considered as `bestMatch`. One in progress wins, the most
    /// recently started first, unless it is `endingSoon` and another starts
    /// within `startLead`. With none in progress, the next to start within
    /// `startLead`.
    static func currentEvent(at now: Date,
                             candidates: [CalendarEventCandidate],
                             allowedCalendarIDs: Set<String>) -> CalendarEventMatch? {
        let usable = candidates.filter {
            allowedCalendarIDs.contains($0.calendarID)
                && !$0.isAllDay && !$0.isDeclined && !$0.isCanceled && $0.end > $0.start
        }
        // Ties go to the earlier title, then end and calendar id, so the
        // answer never depends on the order the calendar returned them in.
        func tieBreak(_ a: CalendarEventCandidate, _ b: CalendarEventCandidate) -> Bool {
            if a.title != b.title { return a.title < b.title }
            if a.end != b.end { return a.end < b.end }
            return a.calendarID < b.calendarID
        }
        let inProgress = usable.filter { $0.start <= now && now < $0.end }
            .min { a, b in a.start != b.start ? a.start > b.start : tieBreak(a, b) }
        let upcoming = usable.filter { $0.start > now && $0.start.timeIntervalSince(now) <= startLead }
            .min { a, b in a.start != b.start ? a.start < b.start : tieBreak(a, b) }
        let chosen: CalendarEventCandidate?
        if let inProgress, let upcoming, inProgress.end.timeIntervalSince(now) < endingSoon {
            chosen = upcoming
        } else {
            chosen = inProgress ?? upcoming
        }
        guard let event = chosen else { return nil }
        return CalendarEventMatch(title: event.title,
                                  start: event.start,
                                  end: event.end,
                                  calendarName: event.calendarName,
                                  attendees: humanAttendees(event.attendees))
    }

    private static func isBetter(_ event: CalendarEventCandidate,
                                 _ overlap: TimeInterval,
                                 than current: (event: CalendarEventCandidate, overlap: TimeInterval),
                                 window: DateInterval) -> Bool {
        if overlap != current.overlap { return overlap > current.overlap }
        let distance = abs(event.start.timeIntervalSince(window.start))
        let currentDistance = abs(current.event.start.timeIntervalSince(window.start))
        if distance != currentDistance { return distance < currentDistance }
        // Nothing left to prefer one by; the rest only makes the order total.
        // Two events still equal after this differ at most in attendees.
        let other = current.event
        if event.title != other.title { return event.title < other.title }
        if event.start != other.start { return event.start < other.start }
        if event.end != other.end { return event.end < other.end }
        if event.calendarID != other.calendarID { return event.calendarID < other.calendarID }
        return event.calendarName < other.calendarName
    }

    // MARK: - Attendees

    /// The people on an invitation: rooms, equipment, distribution lists and
    /// bot addresses dropped, duplicates (one address invited twice) folded,
    /// and the calendar's owner moved to the front. Everyone else keeps the
    /// order the calendar gave.
    static func humanAttendees(_ attendees: [CalendarEventCandidate.Attendee])
        -> [CalendarEventMatch.Attendee] {
        var seenEmails = Set<String>()
        var owner: [CalendarEventMatch.Attendee] = []
        var others: [CalendarEventMatch.Attendee] = []
        for attendee in attendees {
            guard attendee.kind == .person || attendee.kind == .unknown else { continue }
            let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedEmail = (email?.isEmpty ?? true) ? nil : email
            if let resolvedEmail {
                guard !isAutomatedAddress(resolvedEmail),
                      seenEmails.insert(resolvedEmail.lowercased()).inserted else { continue }
            }
            let trimmedName = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // An invitee the calendar has no display name for is shown by
            // address; one with neither is nobody we can list.
            guard let name = trimmedName.isEmpty ? resolvedEmail : trimmedName else { continue }
            let entry = CalendarEventMatch.Attendee(name: name, email: resolvedEmail)
            if attendee.isCurrentUser { owner.append(entry) } else { others.append(entry) }
        }
        return owner + others
    }

    /// Whether `email` is plainly not a person's mailbox. Kept to patterns
    /// that are unambiguous: a miss leaves a bot on the attendee list, a
    /// false hit removes a real person from it.
    static func isAutomatedAddress(_ email: String) -> Bool {
        let lowered = email.lowercased()
        guard let at = lowered.lastIndex(of: "@") else { return false }
        let local = String(lowered[..<at])
        let domain = String(lowered[lowered.index(after: at)...])

        // Google Calendar's own addresses for rooms, shared calendars and
        // imported feeds.
        if domain.hasSuffix(".calendar.google.com") { return true }
        if automatedLocalParts.contains(local) { return true }
        if automatedLocalPrefixes.contains(where: local.hasPrefix) { return true }
        // "bot" only as its own word: `standup-bot@`, not `abbot@`.
        let words = local.split(whereSeparator: { "-_.+".contains($0) })
        return words.contains { automatedLocalParts.contains(String($0)) }
    }

    private static let automatedLocalParts: Set<String> = [
        "bot", "noreply", "donotreply", "notetaker", "notifications",
        "mailer-daemon", "postmaster",
    ]

    private static let automatedLocalPrefixes = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
        "calendar-notification",
    ]
}
