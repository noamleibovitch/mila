import SwiftUI

/// "Run a command after each recording", embedded in the Storage settings tab
/// beside the other opt-in destinations for transcripts.
///
/// **Visibility contract**, the same one `ObsidianSettingsSection` keeps: off
/// by default, and while it is off the only thing on screen is one toggle and
/// one line of caption. The command field, the timeout and the test button
/// render only once `settings.enabled` is true.
struct PostRecordingCommandSettingsSection: View {
    @EnvironmentObject private var settings: PostRecordingCommandSettings
    @EnvironmentObject private var runner: PostRecordingCommandRunner
    @EnvironmentObject private var store: RecordingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            enableCard
            if settings.enabled {
                commandCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.tint)
                Toggle("Run a command after each recording", isOn: $settings.enabled)
                    .accessibilityIdentifier("postCommand.enabled.toggle")
                Spacer()
            }
            if settings.enabled {
                Text("When a new recording's transcript and summary are final, Mila runs the command below once, as you. It gets the path of a JSON file describing the recording as its last argument, and MILA_SRT, MILA_TXT, MILA_AUDIO, MILA_HANDOFF and MILA_RECORDING_ID in its environment. Use it to copy the subtitles somewhere, call a webhook, or start an agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off. Turn this on to run a script or executable of your own each time a recording finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("/Users/you/bin/after-recording.sh --flag value", text: $settings.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("postCommand.command.field")
                Text("A full path, then any fixed arguments. Mila launches it directly, not through a shell, so pipes, variables and globs are not expanded. Put those in the script.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = settings.status.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("postCommand.problem.label")
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text("Stop it after")
                    .font(.callout)
                TextField("600", value: $settings.timeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .accessibilityIdentifier("postCommand.timeout.field")
                Text("seconds")
                    .font(.callout)
                Spacer()
            }
            Divider()
            HStack(spacing: 8) {
                Button("Run on Latest Recording") {
                    if let latest { runner.run(recordingID: latest.id, trigger: .manual) }
                }
                .disabled(latest == nil || !settings.isReady)
                .accessibilityIdentifier("postCommand.test.button")
                if let lastRun = runner.lastRun {
                    Text(lastRun.message)
                        .font(.caption)
                        .foregroundStyle(lastRun.isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The newest finished, non-trashed recording — what the test button runs
    /// the command against.
    private var latest: Recording? {
        store.recordings
            .filter { !$0.isTrashed && $0.status == .completed }
            .max { $0.createdAt < $1.createdAt }
    }
}
