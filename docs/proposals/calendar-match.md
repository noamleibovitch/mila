# Proposal: name a recording after the calendar event it overlapped

Draft of an upstream issue. Not filed.

## Problem

A recording Mila makes of a meeting is saved as `Meeting · 15 Nov 2026 at 10:00`. The name that would help is already on the user's calendar: "Weekly sync", "Budget review with Dana". Today the options are to type it before or after recording, or to let the LLM title job guess one from the transcript. The LLM guess costs a CLI call per recording, needs a provider configured, and names the content of the conversation, which is often not what the meeting is called.

Mila has no calendar code at all. #384 asks for a calendar connection to join meetings and stop recording when they end. That work needs the same two things this one does: permissioned read access to the user's calendars, and a rule for deciding which event a stretch of time belongs to.

## Proposal

An opt-in setting, Settings ▸ Meetings ▸ "Match recordings to calendar events". Off by default.

When a recording finishes and its transcript is final, Mila looks at the calendars the user ticked, finds the event the recording overlapped, and:

1. stores it on the recording as `calendarEvent` (title, start, end, calendar name, attendees);
2. uses the event's title as the recording's title, if the title is still the machine default.

The LLM title job stays as the fallback. It runs when there is no match, when the event has no title, or when the feature is off. When the calendar titles a recording the LLM call is skipped.

A title the user typed is never replaced. That covers a name typed before recording, one typed in the rename sheet while transcription runs, and a rename in the list.

### Matching rules

The recording window is `createdAt - duration` to `createdAt`. `Recording.createdAt` is stamped when the recording stops.

- Only events from calendars the user ticked.
- All-day events are skipped. So are events the user declined and events the organiser cancelled.
- The event with the largest absolute overlap wins.
- A match needs an overlap of at least `min(5 minutes, 20% of the recording)`.
- No qualifying event means no match. Mila never picks the nearest event as a guess.
- Ties go to the event that starts nearer the recording's start, then to the earlier title, so the answer does not depend on the order EventKit returns events in.

Attendees are the people on the invitation. Rooms, equipment and distribution lists are dropped, and so are addresses that are plainly automated (`noreply@`, `*-bot@`, `*.calendar.google.com`). The calendar's owner is listed first.

### Privacy

- The system permission prompt appears only when the user turns the setting on. Nothing asks at launch or when Settings opens.
- After access is granted no calendar is read until the user ticks it. A shared team calendar or a partner's calendar sits in the same account as the user's own, so "access granted" does not mean "read everything".
- Mila queries only the recording's own time window, once per recording.
- The match is stored in `recordings.json` on the user's Mac. It is exposed over the MCP helper as `calendar_event` on `list_recordings` and `get_transcript`, behind the existing MCP consent.
- It does not travel in a `.milashare`. The attendee list is other people's names and email addresses from the sender's calendar, and sharing a recording is not consent to pass those on. The title the event gave the recording travels as the title.
- Logs record counts only, never an event title or an attendee.

### Structure

Three pieces, separate so #384 can build on them:

- `CalendarEventProviding`, a protocol over EventKit with one real implementation. It reports the access state, requests access, lists calendars and returns events for an interval. Tests inject a fake.
- `CalendarEventMatcher`, pure functions with no EventKit types. Takes a window and candidate events, returns the best match or nil.
- `CalendarSettings` and `CalendarEventLookup`. The settings object owns `calendar.enabled` and `calendar.allowedCalendarIDs`; `isReady` means enabled, access granted and at least one calendar ticked. The lookup joins the gate, the read and the rules.

`project.yml` gains `NSCalendarsFullAccessUsageDescription` and the `com.apple.security.personal-information.calendars` entitlement. The app runs with the hardened runtime, which denies calendar access without the entitlement. The deployment target is macOS 14, so `EKEventStore.requestFullAccessToEvents` is used directly.

## Scope

- The setting, permission state and calendar checklist in Settings ▸ Meetings.
- The match at the end of a recording made in Mila, and the title.
- `calendarEvent` in `recordings.json`, mirrored in MilaKit and returned by the MCP tools.
- Unit tests for the matcher, the settings gate, the post-recording wiring and the persistence contract.

## Deliberately left out

- Joining meetings, join links, auto-start and auto-stop. That is #384.
- Reminders and notifications for upcoming events.
- Showing the matched event in the recording detail view. The data is stored; no view reads it yet.
- Using attendees to name speakers or to fill the speaker picker. An invitation says who was invited. It does not say who spoke, and a wrong name accepted into a voice profile follows that voice into later recordings.
- Calendar fields as variables in LLM prompts.
- Matching recordings that already exist, imported audio files and Voice Memos. An imported file's `createdAt` is not the time a meeting ended, so the window rule does not hold for it.
- Re-matching when an event changes. The stored event is a snapshot of the calendar when the recording finished.
- MDM management of the setting. It is not a `.milaconfig` field.

## Open questions

- Recordings stopped because the Mac went to sleep, and a recording that finishes while the rename sheet is still open for the previous one, do not go through `PostRecordingCoordinator.present`, so they get neither an LLM title nor a calendar match. Should the match move to a hook that every finished recording reaches?
- The window uses the duration of the audio on disk. If capture died early the window starts later than the recording really did. The overlap threshold absorbs small errors. Is that enough?
- Should the checklist start with the user's default calendar ticked, to save a click, or stay empty?
- Is `calendar_event` the right thing to expose over MCP by default, given it carries attendee email addresses, or should it sit behind its own toggle?
