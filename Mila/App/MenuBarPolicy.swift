import Foundation

/// Pure menu-bar state and policy. Kept free of SwiftUI/AppKit so the whole
/// state machine — including every capture source and the idle/blocked
/// combinations — can be unit-tested without a running app or a status item.
///
/// The menu is a leaf observer of this state. It deliberately never reads
/// `TranscriptionService.progress`, `RecordingSession.meters` or the elapsed
/// clock: those publish at audio/timer cadence and must not gain a new
/// App-level subscriber (`AppSceneChurnTests`, #280). Processing is derived
/// from the service's deduplicated job IDs/state only.
enum MenuBarStatus: String, CaseIterable, Equatable {
    case stopping
    case starting
    case paused
    case recording
    case preparing
    case processing
    case importing
    case chooseSource
    case ready

    /// The full menu-bar/status-menu sentence. Always names Mila and the
    /// state, so the status item remains meaningful with VoiceOver and in a
    /// crowded menu bar.
    var accessibilityLabel: String { "Mila — \(title)" }

    var title: String {
        switch self {
        case .stopping: return "Stopping Recording"
        case .starting: return "Starting Recording"
        case .paused: return "Recording Paused"
        case .recording: return "Recording"
        case .preparing: return "Preparing Model"
        case .processing: return "Processing"
        case .importing: return "Busy Importing"
        case .chooseSource: return "Choose Audio Source"
        case .ready: return "Ready"
        }
    }

    /// One distinct SF Symbol per state. Shape, not colour, carries the
    /// state so the icon is still readable without colour perception.
    var symbolName: String {
        switch self {
        case .stopping: return "stop.circle"
        case .starting: return "mic"
        case .paused: return "pause.circle"
        case .recording: return "record.circle"
        case .preparing: return "hourglass"
        case .processing: return "gearshape"
        case .importing: return "arrow.down.doc"
        case .chooseSource: return "mic.slash"
        case .ready: return "waveform"
        }
    }

    /// True for the two states in which the user's capture is live (running
    /// or paused) and Stop must stay available.
    var isCapturing: Bool {
        self == .recording || self == .paused
    }
}

/// Everything the policy needs, expressed in existing controller/session
/// types so tests can drive the exact `.recordingApp` / `.recordingMic`
/// sources that are hard to bring up on CI.
struct MenuBarStatusInput {
    var activeJob: QuickActionsController.ActiveJob = .none
    var sessionState: RecordingSession.State = .idle
    var isStoppingRecording = false
    /// Synchronous bring-up window, before `activeJob` becomes `.starting`.
    var isCaptureStartInFlight = false
    var isPreparingModel = false
    /// A share import or a file import is holding/occupying the app.
    var isImporting = false
    /// Transcription/diarization job state — never `progress`.
    var isTranscriptionBusy = false
    var microphoneEnabled = true
    var appAudioEnabled = true
}

enum MenuBarPolicy {
    /// Priority: a stop or start in flight, then active capture (paused or
    /// running), then model preparation, background transcription work and
    /// imports, then the idle states. Active capture deliberately outranks
    /// preparation/processing: the user's recording is the thing they must
    /// still be able to stop from the menu.
    static func status(for input: MenuBarStatusInput) -> MenuBarStatus {
        if input.isStoppingRecording || input.sessionState == .stopping {
            return .stopping
        }
        if case .starting = input.activeJob {
            return .starting
        }
        if input.isCaptureStartInFlight {
            return .starting
        }
        if isCaptureJob(input.activeJob) {
            return input.sessionState == .paused ? .paused : .recording
        }
        if input.isPreparingModel {
            return .preparing
        }
        if input.isTranscriptionBusy {
            return .processing
        }
        if input.isImporting {
            return .importing
        }
        if !input.microphoneEnabled && !input.appAudioEnabled {
            return .chooseSource
        }
        return .ready
    }

    /// Start is available only for an idle controller with a usable source.
    /// The controller's own start paths keep their guards; this mirrors the
    /// existing visible Home-button gates instead of adding new state to the
    /// capture internals.
    static func canStart(_ input: MenuBarStatusInput) -> Bool {
        guard input.activeJob == .none else { return false }
        guard !input.isStoppingRecording else { return false }
        guard !input.isCaptureStartInFlight else { return false }
        guard !input.isPreparingModel else { return false }
        guard !input.isImporting else { return false }
        return input.microphoneEnabled || input.appAudioEnabled
    }

    /// Stop is offered for every active capture source and for paused
    /// capture; it routes straight to `QuickActionsController.stopRecording`.
    static func canStop(_ input: MenuBarStatusInput) -> Bool {
        guard !input.isStoppingRecording, input.sessionState != .stopping else { return false }
        return isCaptureJob(input.activeJob)
    }

    static func isCaptureJob(_ job: QuickActionsController.ActiveJob) -> Bool {
        switch job {
        case .recordingMic, .recording, .recordingApp:
            return true
        case .none, .starting, .importingFile:
            return false
        }
    }

    /// Idle-only caption describing exactly what Start will capture. It is
    /// deliberately absent while busy or recording so the menu never claims
    /// a source that is not the one currently being captured.
    static func sourceCaption(for input: MenuBarStatusInput) -> String? {
        switch status(for: input) {
        case .ready:
            switch (input.microphoneEnabled, input.appAudioEnabled) {
            case (true, true): return "Start records the microphone and app audio."
            case (true, false): return "Start records the microphone."
            case (false, true): return "Start records app audio."
            case (false, false): return "Turn on a source in Open Mila to record."
            }
        case .chooseSource:
            return "Turn on Microphone or App audio in Open Mila to start."
        default:
            return nil
        }
    }
}

/// State-aware copy for the once-only first-close explanation. The idle copy
/// must never imply a recording is running.
struct MenuBarFirstCloseNotice: Equatable {
    static let title = "Mila keeps running"

    let title: String
    let message: String

    static func forStatus(_ status: MenuBarStatus) -> MenuBarFirstCloseNotice {
        let idle = "You can reopen Mila, start a recording, or quit from the Mila icon in the menu bar."
        let message: String
        switch status {
        case .recording:
            message = idle + " Your recording will continue while this window is closed."
        case .paused:
            message = idle + " Your recording will stay paused."
        case .starting, .stopping, .preparing, .processing, .importing:
            message = idle + " Work in progress will continue."
        case .chooseSource, .ready:
            message = idle
        }
        return MenuBarFirstCloseNotice(title: Self.title, message: message)
    }
}

/// The two Home source preferences Start reads. Defaults match HomeView's
/// `@AppStorage` defaults (both ON); a persisted user choice always wins.
enum MenuBarSourceSettings {
    static let microphoneKey = "home.record.microphone"
    static let appAudioKey = "home.record.withSystemAudio"

    static func read(from defaults: UserDefaults) -> (microphone: Bool, appAudio: Bool) {
        (readBool(microphoneKey, defaults: defaults),
         readBool(appAudioKey, defaults: defaults))
    }

    private static func readBool(_ key: String, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

/// The persisted first-close acknowledgement, on injectable defaults so a UI
/// test can use a test-owned suite instead of the user's real preferences.
struct MenuBarFirstCloseStore {
    static let explainedKey = "menuBar.didExplainBackgroundRunning"

    let defaults: UserDefaults

    var hasExplained: Bool { defaults.bool(forKey: Self.explainedKey) }

    /// Set only after the user acknowledges the explanation with Continue.
    func markExplained() {
        defaults.set(true, forKey: Self.explainedKey)
    }
}

enum MenuBarDefaults {
    static let uiTestSuitePrefix = "Mila.MenuBarUITests."
    static let uiTestSuiteArgument = "--ui-test-menu-bar-suite="

    static func uiTestSuiteName(for id: UUID) -> String {
        uiTestSuitePrefix + id.uuidString
    }

    /// `--ui-test-menu-bar-suite=<UUID>` returns a TEST-OWNED defaults suite.
    /// The fixed prefix keeps it inside the test namespace and UUID
    /// validation stops an arbitrary string being used as a suite name.
    /// Anything malformed, or the flag absent, keeps production behaviour.
    static func resolve(arguments: [String] = CommandLine.arguments) -> UserDefaults {
        guard let argument = arguments.first(where: { $0.hasPrefix(uiTestSuiteArgument) }) else {
            return .standard
        }
        let raw = String(argument.dropFirst(uiTestSuiteArgument.count))
        guard let id = UUID(uuidString: raw) else { return .standard }
        return UserDefaults(suiteName: uiTestSuiteName(for: id)) ?? .standard
    }
}
