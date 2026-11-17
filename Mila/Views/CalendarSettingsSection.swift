import AppKit
import SwiftUI

/// Settings → Meetings → "Match recordings to calendar events": the switch,
/// what the system currently allows, and the calendars Mila may read.
///
/// The switch is the only thing that raises the calendar permission prompt
/// (`CalendarSettings.setEnabled`). The checklist starts empty on purpose —
/// see `CalendarSettings` — so the section says so rather than looking done.
struct CalendarSettingsSection: View {
    @EnvironmentObject private var settings: CalendarSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { settings.enabled },
                set: { newValue in Task { await settings.setEnabled(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match recordings to calendar events")
                        .font(.body)
                    Text("When a recording ends, Mila looks for the calendar event it overlapped and names the recording after it. Mila reads only the calendars you tick below, and stores the matched event with the recording. If you enable MCP access, connected clients can also read the event and invited attendees, including their email addresses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.regular)
            .accessibilityIdentifier("meetings.calendar.toggle")

            if settings.enabled {
                switch settings.authorization {
                case .fullAccess:
                    calendarChecklist
                case .notDetermined:
                    // Reached when the prompt is still up, and when the
                    // switch was restored on but the system has forgotten the
                    // answer (a privacy reset): the button asks again.
                    VStack(alignment: .leading, spacing: 6) {
                        status("Mila hasn't been given calendar access yet.",
                               systemImage: "hourglass")
                        Button("Allow Calendar Access…") {
                            Task { await settings.setEnabled(true) }
                        }
                        .controlSize(.small)
                    }
                case .denied:
                    deniedNote
                }
            }
        }
        .onAppear { settings.refresh() }
        // The user may have just granted access in System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }

    @ViewBuilder
    private var calendarChecklist: some View {
        if settings.calendars.isEmpty {
            status("No calendars found. Add an account in System Settings ▸ Internet Accounts.",
                   systemImage: "calendar.badge.exclamationmark")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calendars")
                    .font(.callout.weight(.semibold))
                if !settings.isReady {
                    status("Tick at least one calendar to start matching.",
                           systemImage: "info.circle")
                }
                ForEach(settings.calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { settings.allowedCalendarIDs.contains(calendar.id) },
                        set: { settings.setCalendar(calendar.id, allowed: $0) }
                    )) {
                        HStack(spacing: 6) {
                            Text(calendar.title)
                            if !calendar.sourceTitle.isEmpty {
                                Text(calendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var deniedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            status("Mila doesn't have full access to your calendars, so nothing is matched.",
                   systemImage: "exclamationmark.triangle")
            Button("Open Calendar Privacy Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    private func status(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
