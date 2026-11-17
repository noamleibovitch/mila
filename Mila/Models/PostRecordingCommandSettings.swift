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

    @Published private var storedEnabled: Bool
    @Published private var storedCommand: String
    @Published private var storedTimeout: TimeInterval
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let managedKeys: Set<String>

    var enabled: Bool {
        get { storedEnabled }
        set {
            guard !isManaged(Self.enabledKey), storedEnabled != newValue else { return }
            storedEnabled = newValue
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    var command: String {
        get { storedCommand }
        set {
            guard !isManaged(Self.commandKey), storedCommand != newValue else { return }
            storedCommand = newValue
            defaults.set(newValue, forKey: Self.commandKey)
        }
    }

    var timeoutSeconds: TimeInterval {
        get { storedTimeout }
        set {
            guard !isManaged(Self.timeoutKey) else { return }
            let clamped = Self.clampedTimeout(newValue)
            guard storedTimeout != clamped else { return }
            storedTimeout = clamped
            defaults.set(clamped, forKey: Self.timeoutKey)
        }
    }

    func isManaged(_ key: String) -> Bool { managedKeys.contains(key) }
    var hasManagedValues: Bool { !managedKeys.isEmpty }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default,
         isForced: ((String) -> Bool)? = nil) {
        self.defaults = defaults
        self.fileManager = fileManager
        let forced = isForced ?? { defaults.objectIsForced(forKey: $0) }
        self.managedKeys = Set([Self.enabledKey, Self.commandKey, Self.timeoutKey].filter(forced))
        self.storedEnabled = defaults.bool(forKey: Self.enabledKey)
        self.storedCommand = defaults.string(forKey: Self.commandKey) ?? ""
        let stored = (defaults.object(forKey: Self.timeoutKey) as? NSNumber)?.doubleValue
        self.storedTimeout = Self.clampedTimeout(stored ?? Self.defaultTimeout)
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
        case malformed
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
            case .malformed:
                return "Close all quotes and complete any trailing escape before running the command."
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
        guard hasBalancedQuoting(command) else { return .malformed }
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

    /// Validate exactly the quote/escape grammar accepted by the existing
    /// argv tokenizer, without changing any LLM caller's parsing behavior.
    private static func hasBalancedQuoting(_ input: String) -> Bool {
        let chars = Array(input)
        var single = false
        var double = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if single {
                if c == "'" { single = false }
            } else if double {
                if c == "\"" { double = false }
                else if c == "\\", i + 1 < chars.count,
                        chars[i + 1] == "\"" || chars[i + 1] == "\\" { i += 1 }
            } else if c == "'" { single = true }
            else if c == "\"" { double = true }
            else if c == "\\" {
                guard i + 1 < chars.count else { return false }
                i += 1
            }
            i += 1
        }
        return !single && !double
    }

    /// `command` as it resolves right now. Re-checked on every read: the
    /// script can be moved or lose its executable bit while Mila is open.
    var status: Status { Self.resolve(command, fileManager: fileManager) }

    /// The single gate every automatic path consults: the user turned the
    /// hook on AND the command resolves to something executable.
    var isReady: Bool { enabled && status.invocation != nil }
}
