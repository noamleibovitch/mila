import Foundation

/// Finds the calendar event a finished recording overlapped. The one place
/// the gate (`CalendarSettings.isReady`), the calendar read and the matching
/// rules meet, so no caller can run one without the others.
@MainActor
final class CalendarEventLookup {
    private let settings: CalendarSettings

    init(settings: CalendarSettings) {
        self.settings = settings
    }

    /// Whether a lookup can return anything right now.
    var isReady: Bool { settings.isReady }

    /// The event a recording starting at `now` is most likely for, or nil —
    /// the feature is off or not ready, or nothing is on or about to start
    /// (`CalendarEventMatcher.currentEvent`). A guess for display only.
    func currentEvent(at now: Date = Date()) async -> CalendarEventMatch? {
        guard settings.isReady else { return nil }
        let allowed = settings.allowedCalendarIDs
        let window = DateInterval(start: now, duration: CalendarEventMatcher.startLead)
        let events = await settings.provider.events(in: window, calendarIDs: allowed)
        guard !Task.isCancelled, settings.isReady, settings.allowedCalendarIDs == allowed else { return nil }
        return CalendarEventMatcher.currentEvent(at: now, candidates: events,
                                                 allowedCalendarIDs: allowed)
    }

    /// The event `recording` overlapped, or nil — the feature is off or not
    /// ready, or no event qualifies (`CalendarEventMatcher.bestMatch`).
    ///
    /// `startedAt` is the wall-clock instant the recording began, when the
    /// caller knows it. A paused recording's `duration` leaves the pause
    /// out, so `createdAt - duration` puts its start too late and can hand
    /// the match to the next meeting.
    func match(for recording: Recording, startedAt: Date? = nil) async -> CalendarEventMatch? {
        guard settings.isReady else { return nil }
        let window: DateInterval
        if let startedAt, startedAt < recording.createdAt {
            window = DateInterval(start: startedAt, end: recording.createdAt)
        } else {
            window = CalendarEventMatcher.recordingWindow(createdAt: recording.createdAt,
                                                          duration: recording.duration)
        }
        guard window.duration > 0 else { return nil }
        let allowed = settings.allowedCalendarIDs
        let events = await settings.provider.events(in: window, calendarIDs: allowed)
        guard !Task.isCancelled, settings.isReady, settings.allowedCalendarIDs == allowed else { return nil }
        return CalendarEventMatcher.bestMatch(window: window,
                                              candidates: events,
                                              allowedCalendarIDs: allowed)
    }
}
