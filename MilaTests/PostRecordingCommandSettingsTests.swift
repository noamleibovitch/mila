import XCTest
@testable import Mila

/// `PostRecordingCommandSettings`: off by default, persisted under
/// `postCommand.*`, and "ready" only when the command can actually be launched.
@MainActor
final class PostRecordingCommandSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PostRecordingCommandSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        tempRoot = TestSupport.makeTempRoot(label: "MilaPostCommandSettings")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    /// An executable shell script in the temp root.
    private func makeScript(_ name: String = "hook.sh", executable: Bool = true) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: url.path)
        return url
    }

    func test_forced_values_are_identified_and_refuse_edits_before_publishing() throws {
        let script = try makeScript()
        defaults.set(true, forKey: PostRecordingCommandSettings.enabledKey)
        defaults.set(script.path, forKey: PostRecordingCommandSettings.commandKey)
        defaults.set(45, forKey: PostRecordingCommandSettings.timeoutKey)
        let settings = PostRecordingCommandSettings(defaults: defaults, isForced: { _ in true })
        var publishes = 0
        let observation = settings.objectWillChange.sink { publishes += 1 }
        settings.enabled = false
        settings.command = "/other"
        settings.timeoutSeconds = 100
        XCTAssertTrue(settings.hasManagedValues)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.command, script.path)
        XCTAssertEqual(settings.timeoutSeconds, 45)
        XCTAssertEqual(defaults.string(forKey: PostRecordingCommandSettings.commandKey), script.path)
        XCTAssertEqual(publishes, 0)
        observation.cancel()
    }

    func test_unterminated_quotes_and_escape_are_rejected() {
        XCTAssertEqual(PostRecordingCommandSettings.resolve("/bin/echo 'unfinished"), .malformed)
        XCTAssertEqual(PostRecordingCommandSettings.resolve("/bin/echo \"unfinished"), .malformed)
        XCTAssertEqual(PostRecordingCommandSettings.resolve("/bin/echo trailing\\"), .malformed)
    }

    func test_defaults_are_off_empty_and_ten_minutes() {
        let settings = PostRecordingCommandSettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.command, "")
        XCTAssertEqual(settings.timeoutSeconds, 600)
        XCTAssertFalse(settings.isReady)
    }

    func test_values_persist_under_namespaced_keys() throws {
        let script = try makeScript()
        let settings = PostRecordingCommandSettings(defaults: defaults)
        settings.enabled = true
        settings.command = script.path
        settings.timeoutSeconds = 120

        XCTAssertEqual(defaults.bool(forKey: "postCommand.enabled"), true)
        XCTAssertEqual(defaults.string(forKey: "postCommand.command"), script.path)
        XCTAssertEqual(defaults.double(forKey: "postCommand.timeoutSeconds"), 120)

        let reloaded = PostRecordingCommandSettings(defaults: defaults)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.command, script.path)
        XCTAssertEqual(reloaded.timeoutSeconds, 120)
        XCTAssertTrue(reloaded.isReady)
    }

    func test_timeout_is_clamped_on_write_and_on_load() {
        let settings = PostRecordingCommandSettings(defaults: defaults)
        settings.timeoutSeconds = 0
        XCTAssertEqual(settings.timeoutSeconds, 5)
        settings.timeoutSeconds = 1_000_000
        XCTAssertEqual(settings.timeoutSeconds, 3600)
        XCTAssertEqual(defaults.double(forKey: "postCommand.timeoutSeconds"), 3600,
                       "the clamped value is what gets stored")
        settings.timeoutSeconds = .nan
        XCTAssertEqual(settings.timeoutSeconds, 600)

        // A hand-edited defaults value is clamped too.
        defaults.set(-40, forKey: "postCommand.timeoutSeconds")
        XCTAssertEqual(PostRecordingCommandSettings(defaults: defaults).timeoutSeconds, 5)
    }

    func test_resolve_reports_why_a_command_cannot_run() throws {
        XCTAssertEqual(PostRecordingCommandSettings.resolve("   "), .empty)
        XCTAssertEqual(PostRecordingCommandSettings.resolve("hook.sh --flag"),
                       .notAbsolute("hook.sh"),
                       "a bare name is refused: Mila does not search PATH")

        let missing = tempRoot.appendingPathComponent("nope.sh").path
        XCTAssertEqual(PostRecordingCommandSettings.resolve(missing), .notFound(missing))

        let plain = try makeScript("plain.sh", executable: false)
        XCTAssertEqual(PostRecordingCommandSettings.resolve(plain.path), .notExecutable(plain.path))

        // A directory passes `isExecutableFile` (the x bit means "searchable").
        XCTAssertEqual(PostRecordingCommandSettings.resolve(tempRoot.path),
                       .notExecutable(tempRoot.path))
    }

    func test_resolve_splits_arguments_like_a_shell_would() throws {
        let dir = tempRoot.appendingPathComponent("with space", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("hook.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let status = PostRecordingCommandSettings.resolve(
            "\"\(script.path)\" --dest '/tmp/My Notes' $HOME")
        XCTAssertEqual(status.invocation?.executable.path, script.path)
        XCTAssertEqual(status.invocation?.arguments, ["--dest", "/tmp/My Notes", "$HOME"],
                       "quotes group, and nothing is expanded: $HOME stays literal")
        XCTAssertNil(status.problem)
    }

    func test_resolve_expands_a_leading_tilde() {
        let status = PostRecordingCommandSettings.resolve("~/definitely-not-here-\(UUID()).sh")
        guard case .notFound(let path) = status else {
            return XCTFail("expected .notFound, got \(status)")
        }
        XCTAssertTrue(path.hasPrefix("/"), "the tilde was expanded to a full path: \(path)")
    }

    /// `.claude/rules/feature-gates.md`: ready is "enabled AND launchable".
    func test_isReady_needs_both_the_switch_and_a_launchable_command() throws {
        let script = try makeScript()
        let settings = PostRecordingCommandSettings(defaults: defaults)

        settings.command = script.path
        XCTAssertFalse(settings.isReady, "a valid command with the switch off is not ready")

        settings.enabled = true
        XCTAssertTrue(settings.isReady)

        settings.command = tempRoot.appendingPathComponent("gone.sh").path
        XCTAssertFalse(settings.isReady, "enabled with a command that does not resolve is not ready")

        // Re-checked on every read: the script losing its x bit flips it.
        settings.command = script.path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        XCTAssertFalse(settings.isReady)
    }

    /// The command can carry a webhook URL or a token as an argument, so the
    /// support bundle reports its length, not its text.
    func test_diagnostic_bundle_withholds_the_command_text() {
        let command = "/Users/dana/bin/hook.sh --url https://example.test/hook/abc123"
        let scoped = DiagnosticReporter.scopedSettings(from: [
            "postCommand.enabled": true,
            "postCommand.command": command,
            "postCommand.timeoutSeconds": 600
        ])
        XCTAssertEqual(scoped["postCommand.command"] as? String, "<\(command.count) chars>")
        XCTAssertEqual(scoped["postCommand.enabled"] as? Bool, true)
        XCTAssertNotNil(scoped["postCommand.timeoutSeconds"])
    }
}
