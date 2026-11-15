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

    /// The event `recording` overlapped, or nil — the feature is off or not
    /// ready, or no event qualifies (`CalendarEventMatcher.bestMatch`).
    func match(for recording: Recording) -> CalendarEventMatch? {
        guard settings.isReady else { return nil }
        let window = CalendarEventMatcher.recordingWindow(createdAt: recording.createdAt,
                                                          duration: recording.duration)
        guard window.duration > 0 else { return nil }
        let allowed = settings.allowedCalendarIDs
        let events = settings.provider.events(in: window, calendarIDs: allowed)
        return CalendarEventMatcher.bestMatch(window: window,
                                              candidates: events,
                                              allowedCalendarIDs: allowed)
    }
}
