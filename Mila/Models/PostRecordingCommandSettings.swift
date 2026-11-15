import Foundation
import Combine

/// User-configurable "run a command after each recording" hook. When enabled
/// and ready, Mila runs one executable of the user's choosing once a fresh
/// recording's transcript and summary are final, handing it a JSON file that
/// describes the recording (`PostRecordingHandoff`).
///
/// Mila knows nothing about what the command does. A shell script that copies
/// the `.srt` somewhere, a webhook call and an agent runner are all the same
/// thing from here: an argv Mila launches. That is the point — it is the one
/// generic integration, in place of a built-in destination per service.
///
/// Off by default. `isReady` follows `.claude/rules/feature-gates.md`: it
/// means "enabled AND the command can be launched", never just "enabled".
@MainActor
final class PostRecordingCommandSettings: ObservableObject {
    static let enabledKey = "postCommand.enabled"
    static let commandKey = "postCommand.command"
    static let timeoutKey = "postCommand.timeoutSeconds"

    /// Ten minutes: enough for an agent runner to read a long transcript,
    /// short enough that a hung script does not hold the queue all day.
    static let defaultTimeout: TimeInterval = 600
    /// Bounds on `timeoutSeconds`. The floor keeps a typo ("0") from killing
    /// every run at launch; the ceiling keeps one stuck command from blocking
    /// the runs queued behind it for more than an hour.
    static let timeoutRange: ClosedRange<TimeInterval> = 5...3600

    /// Master switch. Off by default — nothing is ever launched unless the
    /// user turns this on and enters a command.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
        }
    }

    /// The command line: a full path to an executable or script, then any
    /// fixed arguments. Split with `LLMRunner.tokenizeArguments` (quotes and
    /// backslash escapes, no other shell grammar) and launched directly —
    /// never through a shell, so nothing in it is expanded or interpolated,
    /// and nothing from a recording is ever spliced into it.
    @Published var command: String {
        didSet {
            guard command != oldValue else { return }
            defaults.set(command, forKey: Self.commandKey)
        }
    }

    /// How long one run may take before Mila terminates it, in seconds.
    /// Clamped to `timeoutRange`.
    @Published var timeoutSeconds: TimeInterval {
        didSet {
            let clamped = Self.clampedTimeout(timeoutSeconds)
            guard clamped == timeoutSeconds else {
                timeoutSeconds = clamped
                return
            }
            guard timeoutSeconds != oldValue else { return }
            defaults.set(timeoutSeconds, forKey: Self.timeoutKey)
        }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.command = defaults.string(forKey: Self.commandKey) ?? ""
        // `object(forKey:)` so an unset key reads as the default rather than
        // as 0, which the clamp would turn into the 5 s floor.
        let stored = (defaults.object(forKey: Self.timeoutKey) as? NSNumber)?.doubleValue
        self.timeoutSeconds = Self.clampedTimeout(stored ?? Self.defaultTimeout)
    }

    static func clampedTimeout(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultTimeout }
        return min(max(seconds.rounded(), timeoutRange.lowerBound), timeoutRange.upperBound)
    }

    // MARK: - Resolution

    /// What Mila would launch: the executable and the user's fixed arguments.
    /// The handoff path is appended by the runner, per recording.
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    /// Why the command can or cannot be launched. Drives the Settings note.
    enum Status: Equatable {
        case empty
        /// The first token is not a full path. Mila does not search `PATH`:
        /// the app's `PATH` is not the user's shell's, so a bare name would
        /// resolve differently (or not at all) from what they tested in a
        /// terminal.
        case notAbsolute(String)
        case notFound(String)
        case notExecutable(String)
        case ready(Invocation)

        var invocation: Invocation? {
            if case .ready(let invocation) = self { return invocation }
            return nil
        }

        /// One line for Settings; nil when there is nothing to say.
        var problem: String? {
            switch self {
            case .empty:
                return "Enter the full path of a script or executable."
            case .notAbsolute(let token):
                return "“\(token)” is not a full path. Start with / or ~/ — Mila does not search PATH."
            case .notFound(let path):
                return "Nothing found at \(path)."
            case .notExecutable(let path):
                return "\(path) is not executable. Run chmod +x on it."
            case .ready:
                return nil
            }
        }
    }

    /// Resolve `command` against the filesystem. Pure apart from the two
    /// `fileManager` checks, so the tests drive it with a temp directory.
    static func resolve(_ command: String,
                        fileManager: FileManager = .default) -> Status {
        let tokens = LLMRunner.tokenizeArguments(command)
        guard let first = tokens.first, !first.isEmpty else { return .empty }
        let expanded = (first as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .notAbsolute(first) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return .notFound(expanded)
        }
        guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: expanded) else {
            return .notExecutable(expanded)
        }
        return .ready(Invocation(executable: URL(fileURLWithPath: expanded),
                                 arguments: Array(tokens.dropFirst())))
    }

    /// `command` as it resolves right now. Re-checked on every read: the
    /// script can be moved or lose its executable bit while Mila is open.
    var status: Status { Self.resolve(command, fileManager: fileManager) }

    /// The single gate every automatic path consults: the user turned the
    /// hook on AND the command resolves to something executable.
    var isReady: Bool { enabled && status.invocation != nil }
}
