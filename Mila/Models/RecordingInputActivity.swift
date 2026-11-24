import Foundation

/// Normalized display values, never PCM samples or calibrated loudness.
struct RecordingInputLevels: Equatable {
    let microphone: Float
    let appAudio: Float

    init(microphone: Float = 0, appAudio: Float = 0) {
        func bounded(_ value: Float) -> Float {
            value.isFinite ? min(1, max(0, value)) : 0
        }
        self.microphone = bounded(microphone)
        self.appAudio = bounded(appAudio)
    }
}

enum RecordingInputChannel: String, CaseIterable {
    case microphone, appAudio

    var title: String { self == .microphone ? "Microphone" : "App audio" }

    func isEnabled(for source: RecordingSource) -> Bool {
        switch source {
        case .meeting: return true
        case .microphone, .voiceMemo: return self == .microphone
        case .systemAudio: return self == .appAudio
        }
    }

    func level(in levels: RecordingInputLevels) -> Float {
        self == .microphone ? levels.microphone : levels.appAudio
    }

    func status(source: RecordingSource, isPaused: Bool, levels: RecordingInputLevels) -> String {
        guard isEnabled(for: source) else { return "Off" }
        if isPaused { return "Paused" }
        return level(in: levels) > 0.05 ? "Receiving audio" : "Quiet"
    }
}

/// Four seconds of amplitude history at the view's 10 Hz display cadence.
/// Local to the small view, never a high-frequency app-level publisher.
struct RecordingInputHistory {
    static let capacity = 40
    private(set) var microphone = [Float](repeating: 0, count: RecordingInputHistory.capacity)
    private(set) var appAudio = [Float](repeating: 0, count: RecordingInputHistory.capacity)
    private(set) var latest = RecordingInputLevels()

    mutating func append(_ levels: RecordingInputLevels) {
        microphone.removeFirst()
        microphone.append(levels.microphone)
        appAudio.removeFirst()
        appAudio.append(levels.appAudio)
        latest = levels
    }

    func values(for channel: RecordingInputChannel) -> [Float] {
        channel == .microphone ? microphone : appAudio
    }
}
