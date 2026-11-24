import SwiftUI
import Combine

/// Shared live Microphone / App-audio controls and meters for an active
/// recording. Mounted on Home while recording (in place of the idle
/// preference pair) and in its own row under the Live AI header controls.
///
/// Deliberately small and leaf-shaped: it observes `QuickActionsController`
/// and the low-frequency `RecordingSession` state, and its per-leg meters live
/// in `RecordingInputMeter`, which is the ONLY thing here that observes the
/// audio-cadence `RecordingMeters`. No parent, App/root view or transcript
/// view subscribes to the high-frequency values because of this leaf.
///
/// The switches are bound to the session's ACCEPTED inclusion — not to the
/// next-recording `@AppStorage` preferences — so a refused/failed change can
/// never masquerade as applied capture. Starting a previously unopened leg
/// goes through `QuickActionsController.setLiveSource`, which serializes the
/// request through `RecordingSession.setLiveSources`.
struct RecordingInputIndicators: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var session: RecordingSession

    /// The capture engines' `isRunning` flags change at start/stop cadence,
    /// not audio cadence. Mirroring them in this leaf keeps the leg state
    /// ("Included" vs "Unavailable") honest after a watchdog rebuild without
    /// any parent observing the recorders.
    @State private var micIsRunning = false
    @State private var systemIsRunning = false

    private var isPaused: Bool { session.state == .paused }
    private var bothSourcesExcluded: Bool {
        !session.micIncluded && !session.systemIncluded
    }
    private var controlsDisabled: Bool {
        !actions.isRecording
            || actions.isStartingRecording
            || actions.isStoppingRecording
            || session.isChangingLiveSources
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            legRow(.microphone)
            legRow(.appAudio)
            pauseStatus
            errorNotice
        }
        .onReceive(session.mic.$isRunning.removeDuplicates()) { micIsRunning = $0 }
        .onReceive(session.system.$isRunning.removeDuplicates()) { systemIsRunning = $0 }
        .frame(maxWidth: 460, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording inputs")
        .accessibilityIdentifier("recording.inputs")
    }

    // MARK: - One leg

    private func legRow(_ leg: LiveInputSource) -> some View {
        let acceptedIncluded = included(leg)
        let liveState = legState(leg)
        let stateText = stateLabel(liveState, included: acceptedIncluded)
        let meterActive = acceptedIncluded && !isPaused && liveState == .listening

        return HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(
                get: { included(leg) },
                set: { requested in
                    Task { await actions.setLiveSource(leg, included: requested) }
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: leg.symbolName)
                        .font(.callout)
                        .foregroundStyle(.tint)
                    Text(leg.title)
                        .font(.callout)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(controlsDisabled)
            .help(leg.helpText)
            .accessibilityIdentifier(leg.toggleIdentifier)
            .accessibilityHint(leg.hint(for: stateText))

            Spacer(minLength: 4)

            Text(stateText)
                .font(.caption)
                .foregroundStyle(stateColor(liveState))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier(leg.stateIdentifier)

            RecordingInputMeter(leg: leg,
                                label: leg.meterLabel,
                                isActive: meterActive)
                .frame(width: 84)
        }
    }

    // MARK: - Pause reason and hint

    @ViewBuilder
    private var pauseStatus: some View {
        if isPaused {
            if bothSourcesExcluded {
                if session.autoPausedBySourceState {
                    statusLine("Paused: both sources muted",
                               identifier: "recording.inputs.pauseReason")
                    hintLine("Turn on a source to resume.",
                             identifier: "recording.inputs.resumeHint")
                } else {
                    statusLine("Paused by you",
                               identifier: "recording.inputs.pauseReason")
                    hintLine("Turn on a source, then Resume.",
                             identifier: "recording.inputs.resumeHint")
                }
            } else {
                statusLine("Paused by you",
                           identifier: "recording.inputs.pauseReason")
            }
        } else if bothSourcesExcluded {
            hintLine("Turn on a source to resume recording.",
                     identifier: "recording.inputs.resumeHint")
        }
    }

    private func statusLine(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func hintLine(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    // MARK: - Inline error

    @ViewBuilder
    private var errorNotice: some View {
        if let message = actions.liveSourceError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Dismiss") { actions.dismissLiveSourceError() }
                    .buttonStyle(.link)
                    .controlSize(.mini)
                    .accessibilityLabel("Dismiss input message")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording.inputs.error")
        }
    }

    // MARK: - Per-leg state

    private func included(_ leg: LiveInputSource) -> Bool {
        switch leg {
        case .microphone: return session.micIncluded
        case .appAudio: return session.systemIncluded
        }
    }

    private func legState(_ leg: LiveInputSource) -> RecordingSession.LiveLegState {
        switch leg {
        case .microphone:
            // Reading the mirrored @State makes a start/stop flip repaint this
            // row even though the derived state lives on the session.
            _ = micIsRunning
            return session.micLiveState
        case .appAudio:
            _ = systemIsRunning
            return session.systemLiveState
        }
    }

    private func stateLabel(_ state: RecordingSession.LiveLegState,
                            included: Bool) -> String {
        if state == .starting { return "Starting…" }
        if state == .unavailable { return "Unavailable" }
        if isPaused {
            if included { return "Paused" }
            return state == .muted ? "Muted" : "Off"
        }
        switch state {
        case .off: return "Off"
        case .muted: return "Muted"
        case .starting: return "Starting…"
        case .listening: return "Included"
        case .unavailable: return "Unavailable"
        }
    }

    private func stateColor(_ state: RecordingSession.LiveLegState) -> Color {
        switch state {
        case .unavailable, .muted: return .orange
        case .starting: return .secondary
        case .off: return .secondary
        case .listening: return isPaused ? .orange : .primary
        }
    }
}

/// The tiny high-frequency leaf: observes `RecordingMeters` so only this
/// meter repaints at audio cadence, never the toggles, status text or the
/// surrounding recording view.
private struct RecordingInputMeter: View {
    @EnvironmentObject private var meters: RecordingMeters

    let leg: LiveInputSource
    let label: String
    let isActive: Bool

    var body: some View {
        let level = isActive ? rawLevel : 0
        LevelMeterView(level: level, isLive: isActive, label: label)
    }

    private var rawLevel: Float {
        switch leg {
        case .microphone: return meters.micLevel
        case .appAudio: return meters.systemLevel
        }
    }
}

private extension LiveInputSource {
    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .appAudio: return "App audio"
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .appAudio: return "speaker.wave.2.fill"
        }
    }

    var toggleIdentifier: String {
        switch self {
        case .microphone: return "recording.inputs.microphone.toggle"
        case .appAudio: return "recording.inputs.appAudio.toggle"
        }
    }

    var stateIdentifier: String {
        switch self {
        case .microphone: return "recording.inputs.microphone.state"
        case .appAudio: return "recording.inputs.appAudio.state"
        }
    }

    var meterLabel: String {
        switch self {
        case .microphone: return "Microphone level"
        case .appAudio: return "App audio level"
        }
    }

    var helpText: String {
        switch self {
        case .microphone:
            return "Include or mute the microphone while recording. Turning it off keeps the recording and the other source running."
        case .appAudio:
            return "Include or mute app audio while recording. Turning it off keeps the recording and the other source running."
        }
    }

    func hint(for stateText: String) -> String {
        "Currently \(title.lowercased()): \(stateText). Accepted changes also set the source for your next recording."
    }
}
