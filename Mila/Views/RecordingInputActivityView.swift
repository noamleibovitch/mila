import SwiftUI

/// Separate amplitude envelopes from the capture pipeline, before mixing.
/// This leaf polls the meters; neither it nor the transcript/root subscribes
/// to the per-buffer publisher (see #280). No raw audio is retained here.
struct RecordingInputActivityView: View {
    @EnvironmentObject private var session: RecordingSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history = RecordingInputHistory()
    private var usesSeededHistory = false

    init() {}

    #if DEBUG
    /// Deterministic component renders without depending on view/task timing.
    init(seededHistory: RecordingInputHistory) {
        _history = State(initialValue: seededHistory)
        usesSeededHistory = true
    }
    #endif

    private struct SamplingID: Equatable {
        let epoch: Int
        let recording: Bool
        let reduceMotion: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording inputs")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(RecordingInputChannel.allCases, id: \.self) { channel in
                inputRow(channel)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.inputs")
        // Epoch changes BEFORE the session publishes .recording. Including
        // it catches a quick stop/start even if SwiftUI coalesces away .idle.
        .task(id: SamplingID(epoch: session.captureEpoch,
                             recording: session.state == .recording,
                             reduceMotion: reduceMotion)) {
            guard !usesSeededHistory else { return }
            history = RecordingInputHistory()
            guard session.state == .recording else { return }
            let epoch = session.captureEpoch
            while !Task.isCancelled, session.state == .recording, session.captureEpoch == epoch {
                history.append(session.meters.displayLevels())
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    private func inputRow(_ channel: RecordingInputChannel) -> some View {
        let enabled = channel.isEnabled(for: session.source)
        let capturing = enabled && session.state == .recording
        let levels = capturing ? history.latest : RecordingInputLevels()
        let status = channel.status(source: session.source,
                                    isPaused: session.state == .paused, levels: levels)
        let tint: Color = channel == .microphone ? .blue : .teal
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: channel == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(enabled ? tint : .secondary)
                Text(channel.title)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(status)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            InputAmplitudeTrace(values: history.values(for: channel),
                                currentLevel: channel.level(in: levels),
                                isCapturing: capturing, reduceMotion: reduceMotion, tint: tint)
                .frame(height: 28)
                .accessibilityHidden(true)
        }
        // Categorical value only: don't turn audio samples into continuous
        // VoiceOver percentages or live-region announcements.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.title)
        .accessibilityValue(status)
        .accessibilityIdentifier("recording.input.\(channel.rawValue)")
    }
}

private struct InputAmplitudeTrace: View {
    let values: [Float]
    let currentLevel: Float
    let isCapturing: Bool
    let reduceMotion: Bool
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let baseline = Path { path in
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            guard isCapturing else { return }
            if reduceMotion {
                // Essential current-level feedback, without a scrolling trace.
                let rect = CGRect(x: 0, y: size.height / 2 - 3,
                                  width: size.width * CGFloat(currentLevel), height: 6)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(tint))
            } else {
                let step = size.width / CGFloat(max(1, values.count))
                for (index, level) in values.enumerated() where level > 0 {
                    let height = max(1, CGFloat(level) * size.height)
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                      width: max(1, step - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(tint))
                }
            }
        }
    }
}
