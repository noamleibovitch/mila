import EventKit
import Foundation

/// Whether Mila may read the user's calendars.
enum CalendarAuthorization: Equatable {
    /// Never asked. The only state in which asking shows the system prompt.
    case notDetermined
    /// The user said yes to full access — what reading events needs.
    case fullAccess
    /// Denied, restricted by a profile, or write-only. Only System Settings
    /// can change it now; asking again shows nothing.
    case denied
}

/// One of the user's calendars, as the Settings checklist shows it.
struct CalendarInfo: Identifiable, Hashable {
    /// `EKCalendar.calendarIdentifier` — what `CalendarSettings` stores.
    var id: String
    var title: String
    /// The account the calendar belongs to ("iCloud", "Google"), so two
    /// calendars both called "Work" can be told apart.
    var sourceTitle: String
}

/// Read access to the user's calendars. The seam between Mila and EventKit:
/// `EventKitCalendarProvider` is the only real implementation, and tests
/// inject a fake so nothing in the suite touches a real calendar database or
/// raises a permission prompt.
///
/// Nothing here is specific to matching a finished recording — a later
/// feature that needs upcoming events (issue #384) reads them through
/// `events(in:calendarIDs:)` as well.
@MainActor
protocol CalendarEventProviding: AnyObject {
    var authorization: CalendarAuthorization { get }
    /// Ask the system for full calendar access. Shows the permission prompt
    /// only while `authorization` is `.notDetermined`. Returns whether access
    /// is granted afterwards.
    func requestAccess() async -> Bool
    /// The user's event calendars, or none without access.
    func calendars() -> [CalendarInfo]
    /// Events that intersect `interval` in the calendars named by
    /// `calendarIDs`, or none without access.
    func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [CalendarEventCandidate]
}

/// `CalendarEventProviding` over the system calendar database (the one
/// Calendar.app shows: iCloud, Google, Exchange, anything set up in
/// System Settings ▸ Internet Accounts).
@MainActor
final class EventKitCalendarProvider: CalendarEventProviding {
    /// Created on first use, not at launch: nothing should reach for the
    /// calendar database in an install that never turns the feature on.
    private lazy var store = EKEventStore()
    private let eventQueue = DispatchQueue(label: "io.island.mila.calendar.events", qos: .utility)

    var authorization: CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .fullAccess
        // `.authorized` is what macOS 13 and earlier reported; the app's
        // deployment target is 14, where it can no longer be granted.
        // Write-only cannot read events, so it is no access for this purpose.
        case .denied, .restricted, .writeOnly, .authorized: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        // A failed request and a refused one are the same thing to the
        // caller: no access. The state is re-read rather than trusted from
        // the callback so both paths report one truth.
        _ = try? await store.requestFullAccessToEvents()
        return authorization == .fullAccess
    }

    func calendars() -> [CalendarInfo] {
        guard authorization == .fullAccess else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier,
                                title: $0.title,
                                sourceTitle: $0.source?.title ?? "") }
            .sorted {
                ($0.sourceTitle, $0.title, $0.id) < ($1.sourceTitle, $1.title, $1.id)
            }
    }

    func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [CalendarEventCandidate] {
        guard authorization == .fullAccess, !calendarIDs.isEmpty else { return [] }
        // Create, query and consume this store on one serial queue. No
        // EventKit object crosses back to the main actor, only value types.
        let queue = eventQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                let queryStore = EKEventStore()
                let calendars = queryStore.calendars(for: .event)
                    .filter { calendarIDs.contains($0.calendarIdentifier) }
                guard !calendars.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let predicate = queryStore.predicateForEvents(withStart: interval.start,
                                                              end: interval.end,
                                                              calendars: calendars)
                let events = queryStore.events(matching: predicate).map(Self.candidate(from:))
                continuation.resume(returning: events)
            }
        }
    }

    nonisolated private static func candidate(from event: EKEvent) -> CalendarEventCandidate {
        let attendees = (event.attendees ?? []).map(attendee(from:))
        let declined = (event.attendees ?? []).contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        }
        return CalendarEventCandidate(title: event.title ?? "",
                                      start: event.startDate,
                                      end: event.endDate,
                                      isAllDay: event.isAllDay,
                                      calendarID: event.calendar?.calendarIdentifier ?? "",
                                      calendarName: event.calendar?.title ?? "",
                                      attendees: attendees,
                                      isDeclined: declined,
                                      isCanceled: event.status == .canceled)
    }

    nonisolated private static func attendee(from participant: EKParticipant) -> CalendarEventCandidate.Attendee {
        let kind: CalendarEventCandidate.AttendeeKind
        switch participant.participantType {
        case .person: kind = .person
        case .room: kind = .room
        case .resource: kind = .resource
        case .group: kind = .group
        case .unknown: kind = .unknown
        @unknown default: kind = .unknown
        }
        // EventKit has no email property; an invitee's address is the
        // `mailto:` URL it is identified by.
        let url = participant.url
        let email = url.scheme?.lowercased() == "mailto"
            ? (url as NSURL).resourceSpecifier?.removingPercentEncoding
            : nil
        return CalendarEventCandidate.Attendee(name: participant.name ?? "",
                                               email: email,
                                               kind: kind,
                                               isCurrentUser: participant.isCurrentUser)
    }
}
