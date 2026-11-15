import Foundation
import Combine
import OSLog

// The recording's UUID is the public correlation key on every line here, with
// the trigger, exit status, duration and byte counts beside it. Nothing else
// is public: the title is a meeting name, the audio and sidecar paths are
// derived from it, and the command's stdout/stderr are whatever the user's
// script printed about the meeting. See `bugbot-rules/no-user-content-in-logs.md`.
private let postCommandLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                    category: "PostRecordingCommand")

/// Runs the user's post-recording command (`PostRecordingCommandSettings`)
/// once per fresh recording, after its summary state is final.
///
/// Sequencing is `ObsidianExporter`'s, for the same reasons: a fresh
/// completion is marked `pending`, and the run starts from
/// `RecordingSummarizer.onSummaryFinished` — which also fires on every skip
/// path, so the hook runs with summaries off or no LLM configured. A recording
/// that was never marked (the launch-time summary backfill) never runs, and a
/// re-transcription is not marked either: the command has side effects Mila
/// cannot see, so an automatic second run is not assumed to be harmless. The
/// context menu's "Run Post-Recording Command" is the rerun path.
///
/// Before each run Mila writes `<root>/handoff/<recording-id>.json`
/// (`PostRecordingHandoff`) and passes its path as the LAST argument, plus
/// `MILA_*` environment variables for the scripts that only want one file.
/// Recording content reaches the command through that file and those paths,
/// never through the command line itself.
///
/// Runs are serial. A Voice Memos sync can complete dozens of recordings in a
/// row, and each run parks a child process and its reader threads; one at a
/// time is the caller-side bound `.claude/rules/python-subprocess.md` asks
/// for, and it is also what a filing script that appends to one file wants.
@MainActor
final class PostRecordingCommandRunner: ObservableObject {
    enum Trigger: String {
        /// A fresh recording's summary state settled.
        case automatic
        /// The context menu or the Settings test button.
        case manual
    }

    /// Everything one launch needs, snapshotted on the main actor so the
    /// blocking side touches no settings object.
    struct ProcessRequest: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: URL
        let timeout: TimeInterval
    }

    struct ProcessResult: Sendable, Equatable {
        var exitCode: Int32 = 0
        var timedOut = false
        var cancelled = false
        var stdout = ""
        var stderr = ""
        /// Set when the process never started. `launchFailure` is Cocoa's own
        /// sentence for the banner (it quotes the path, which is the user's
        /// to see); `launchFailureCode` is the `NSError` domain and code, the
        /// only part that goes to the log.
        var launchFailure: String?
        var launchFailureCode: String?
    }

    /// Injectable launch seam, so the sequencing tests can assert what would
    /// be run without spawning anything. Defaults to `spawn`.
    typealias Execute = @Sendable (ProcessRequest) async -> ProcessResult

    /// The most recent run's outcome, for the Settings section. Published at
    /// most once per run — far below anything `AppSceneChurnTests` budgets.
    struct LastRun: Equatable {
        let recordingID: UUID
        let message: String
        let isError: Bool
    }
    @Published private(set) var lastRun: LastRun?

    /// Handoff files kept on disk. Each one repeats a recording's summary and
    /// action items, so they are pruned rather than left to accumulate; twenty
    /// covers a day of meetings for a script that reads them late.
    static let maxHandoffFiles = 20

    /// Late-bound by `MilaApp` to `PostRecordingCoordinator.postStatus`, the
    /// banner the Send action already reports through.
    var postStatus: ((_ message: String, _ isError: Bool) -> Void)?

    private let store: RecordingStore
    private let settings: PostRecordingCommandSettings
    private let fileManager: FileManager
    private let execute: Execute

    /// `<root>/handoff`. Anchored to the store's ORIGINAL root like the live
    /// sidecar and the store-location pointer: it is app state, not part of
    /// the library, so it does not travel with a relocated recordings folder
    /// — and a test's temp root keeps it out of the real Application Support.
    let handoffDirectory: URL
    /// The command's cwd: a directory Mila owns that holds nothing of the
    /// user's. Never `$HOME` or `/` — file access by the child is attributed
    /// to Mila's bundle id, so a script that walks its cwd from there would
    /// raise "Mila would like to access Desktop" prompts (the same reasoning
    /// as `LLMRunner.sandboxDirectory`). Separate from `handoffDirectory` so
    /// whatever a script drops in its cwd is not mistaken for a handoff.
    let workingDirectory: URL

    private var pending: Set<UUID> = []

    /// Recordings permanently deleted during this session — a tombstone, not
    /// a cleared flag, for the reason `ObsidianExporter.discarded` documents:
    /// `QuickActionsController.finalizeTail` outlives `cancelAndDiscard` and
    /// ends by calling `markPending` for the same id. Session-scoped: a
    /// discard only has to beat work already in flight.
    private var discarded: Set<UUID> = []

    /// Queued and running work, keyed per recording. Cancelling the task is
    /// what stops the child: `spawn` turns it into SIGTERM, then SIGKILL, for
    /// the command's whole process group.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The most recently queued run. Each new run awaits it first, which is
    /// the whole serial queue.
    private var tail: Task<Void, Never>?

    private var cancellables: Set<AnyCancellable> = []

    init(store: RecordingStore,
         settings: PostRecordingCommandSettings,
         fileManager: FileManager = .default,
         execute: @escaping Execute = { await PostRecordingCommandRunner.spawn($0) }) {
        self.store = store
        self.settings = settings
        self.fileManager = fileManager
        self.execute = execute
        self.handoffDirectory = store.originalRootDirectory
            .appendingPathComponent("handoff", isDirectory: true)
        self.workingDirectory = store.originalRootDirectory
            .appendingPathComponent("post-recording-command", isDirectory: true)

        // Every permanent delete — context menu, Empty Recently Deleted, the
        // rename sheet's Discard — stops that recording's run and removes its
        // handoff, in the same main-actor turn as the delete. Same hook
        // `PostRecordingCoordinator` and `RecordingSummarizer` cancel on.
        store.permanentlyDeleted
            .sink { [weak self] ids in
                for id in ids { self?.discard(id) }
            }
            .store(in: &cancellables)
        // Moving a recording to Recently Deleted stops its run too. No
        // tombstone: a trashed recording can be restored and run by hand.
        // The scan is skipped unless something is queued or running.
        store.$recordings
            .sink { [weak self] recordings in
                guard let self, !self.tasks.isEmpty else { return }
                for recording in recordings where recording.isTrashed {
                    self.cancelRun(for: recording.id)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Pending gate

    /// Ignores an id the user has already thrown away — see `discarded`.
    func markPending(_ id: UUID) {
        guard !discarded.contains(id) else { return }
        pending.insert(id)
    }
    func isPending(_ id: UUID) -> Bool { pending.contains(id) }
    func clearPending(_ id: UUID) { pending.remove(id) }

    /// The `onSummaryFinished` entry point: run the command for `recording`
    /// if a fresh completion marked it, and consume the mark either way.
    func runIfPending(_ recording: Recording) {
        guard pending.remove(recording.id) != nil else { return }
        run(recordingID: recording.id, trigger: .automatic)
    }

    // MARK: - Running

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Queue the command for `recordingID`. Returns false, queueing nothing,
    /// when that recording was permanently deleted or already has a run
    /// queued or in flight — two runs of one recording would race each other
    /// over the same handoff file.
    ///
    /// Everything else is decided when the run reaches the front of the
    /// queue, from the live row and the current settings: by then a queued
    /// recording may have been trashed, or the hook turned off.
    @discardableResult
    func run(recordingID id: UUID, trigger: Trigger) -> Bool {
        guard !discarded.contains(id) else { return false }
        guard tasks[id] == nil else {
            if trigger == .manual {
                postStatus?("The post-recording command is already running for this recording.", false)
            }
            return false
        }
        let previous = tail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.perform(id, trigger: trigger)
            // Only relinquish the slot if we finished on our own. A cancel
            // already removed it (`cancelRun`), and a later manual run may
            // have taken it since.
            if !Task.isCancelled { self.tasks[id] = nil }
        }
        tasks[id] = task
        tail = task
        return true
    }

    /// Wait until every queued run has finished. For tests.
    func awaitIdle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    /// The recording is gone for good: tombstone the id, stop a queued or
    /// running command for it, and delete its handoff file — which repeats
    /// the title, summary and action items the user just deleted.
    func discard(_ id: UUID) {
        discarded.insert(id)
        pending.remove(id)
        cancelRun(for: id)
        try? fileManager.removeItem(at: handoffURL(for: id))
    }

    private func cancelRun(for id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    private func perform(_ id: UUID, trigger: Trigger) async {
        // Deleted stays deleted, and the LIVE row is the one described: the
        // caller's copy can predate the summary, a rename, or a trash.
        guard !discarded.contains(id),
              let recording = store.recordings.first(where: { $0.id == id }),
              !recording.isTrashed else {
            postCommandLog.log("skipped \(id.uuidString, privacy: .public): recording is gone or trashed")
            return
        }
        guard settings.enabled, let invocation = settings.status.invocation else {
            postCommandLog.log("skipped \(id.uuidString, privacy: .public): command is off or not launchable")
            if trigger == .manual {
                report(id, "Post-recording command isn't ready — check Settings → Storage.", isError: true)
            }
            return
        }

        let handoff = PostRecordingHandoff(recording: recording,
                                           audio: store.audioURL(for: recording),
                                           srt: store.subtitleURL(for: recording),
                                           txt: store.transcriptURL(for: recording),
                                           summary: store.summaryURL(for: recording),
                                           fileManager: fileManager)
        let handoffURL = handoffURL(for: id)
        do {
            try writeHandoff(handoff, to: handoffURL)
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            // Domain + code are public (they separate a full disk from a
            // permissions problem); the Cocoa message quotes the path.
            let ns = error as NSError
            postCommandLog.error("""
                failed \(id.uuidString, privacy: .public): could not write the handoff \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)] \
                \(error.localizedDescription, privacy: .private)
                """)
            report(id, "Post-recording command not run: couldn't write the handoff file.", isError: true)
            return
        }
        pruneHandoffs()

        var environment = LLMRunner.childEnvironment(for: invocation.executable)
        environment["MILA_RECORDING_ID"] = handoff.id
        environment["MILA_HANDOFF"] = handoffURL.path
        // Assigning nil removes the key, so a file that does not exist is an
        // UNSET variable — never a stale value inherited from Mila's own
        // environment, and never a path to nothing.
        environment["MILA_SRT"] = handoff.files.srt
        environment["MILA_TXT"] = handoff.files.txt
        environment["MILA_AUDIO"] = handoff.files.audio
        let timeout = settings.timeoutSeconds
        let request = ProcessRequest(executable: invocation.executable,
                                     arguments: invocation.arguments + [handoffURL.path],
                                     environment: environment,
                                     workingDirectory: workingDirectory,
                                     timeout: timeout)

        if trigger == .manual {
            postStatus?("Running post-recording command…", false)
        }
        postCommandLog.log("started \(id.uuidString, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) timeout=\(Int(timeout), privacy: .public)s")
        let started = Date()
        let result = await execute(request)
        let elapsed = Date().timeIntervalSince(started)

        if result.cancelled || Task.isCancelled {
            // The recording was deleted or trashed mid-run. Deliberate, so no
            // banner; `discard` has already removed the handoff.
            postCommandLog.log("cancelled \(id.uuidString, privacy: .public) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
            return
        }
        if let code = result.launchFailureCode {
            postCommandLog.error("failed \(id.uuidString, privacy: .public): could not launch [\(code, privacy: .public)]")
        } else if result.timedOut {
            postCommandLog.error("timed out \(id.uuidString, privacy: .public) after \(Int(timeout), privacy: .public)s — terminated")
        } else {
            // Byte counts only: the output is the script's, about the meeting.
            postCommandLog.log("""
                finished \(id.uuidString, privacy: .public) exit=\(result.exitCode, privacy: .public) \
                duration=\(elapsed, format: .fixed(precision: 1), privacy: .public)s \
                stdout=\(result.stdout.utf8.count, privacy: .public)B \
                stderr=\(result.stderr.utf8.count, privacy: .public)B
                """)
        }
        let outcome = Self.statusMessage(for: result, timeout: timeout)
        report(id, outcome.message, isError: outcome.isError)
    }

    private func report(_ id: UUID, _ message: String, isError: Bool) {
        lastRun = LastRun(recordingID: id, message: message, isError: isError)
        postStatus?(message, isError)
    }

    /// The banner for a finished run. A failure quotes the command's own
    /// first line of stderr (stdout when stderr is empty): it is the user's
    /// script, on their screen, and the only thing that turns "exit 1" into
    /// something they can act on. The log gets none of it.
    static func statusMessage(for result: ProcessResult,
                              timeout: TimeInterval) -> (message: String, isError: Bool) {
        if let failure = result.launchFailure {
            return ("Post-recording command couldn't start: \(failure)", true)
        }
        if result.timedOut {
            return ("Post-recording command was stopped after \(Int(timeout))s without finishing.", true)
        }
        guard result.exitCode != 0 else {
            return ("Post-recording command finished.", false)
        }
        let output = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.stdout : result.stderr
        let firstLine = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let detail = firstLine.isEmpty ? "" : ": \(firstLine.prefix(160))"
        return ("Post-recording command failed (exit \(result.exitCode))\(detail)", true)
    }

    // MARK: - Handoff files

    func handoffURL(for id: UUID) -> URL {
        handoffDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Owner-only, like the transcript it summarises: the directory is 0700
    /// and the file 0600, written atomically so a command never reads half
    /// of one.
    private func writeHandoff(_ handoff: PostRecordingHandoff, to url: URL) throws {
        try fileManager.createDirectory(at: handoffDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try handoff.encoded().write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Keep the newest `maxHandoffFiles` handoffs and delete the rest. Only
    /// files named `<uuid>.json` are considered, so anything else that ends
    /// up in the directory is left alone. The file just written is the
    /// newest, and runs are serial, so no running command loses its handoff.
    private func pruneHandoffs() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: handoffDirectory,
                                                                 includingPropertiesForKeys: keys)
        else { return }
        let handoffs = entries
            .filter { $0.pathExtension == "json"
                && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { url -> (url: URL, modified: Date) in
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                return (url, date ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
        for stale in handoffs.dropFirst(Self.maxHandoffFiles) {
            try? fileManager.removeItem(at: stale.url)
        }
    }

    // MARK: - Process

    /// Launch the command and wait for it, off the main actor.
    ///
    /// `LLMRunner.executeProcess` is the one subprocess implementation in the
    /// app, and it already does what `.claude/rules/python-subprocess.md`
    /// requires: both pipes drained on threads of their own before the exit
    /// is read, the exit observed by `terminationHandler` with a
    /// `waitUntilExit` backstop, the timeout enforced by SIGTERM then SIGKILL
    /// on the child's process group, every wait bounded. It blocks for the
    /// child's whole life, so it gets a dedicated thread (`BlockingWork`),
    /// and a cancelled Task reaches the child through `ProcessHandle`.
    nonisolated static func spawn(_ request: ProcessRequest) async -> ProcessResult {
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                BlockingWork.onDedicatedThread(named: "io.island.mila.postcommand.run") {
                    do {
                        let outcome = try LLMRunner.executeProcess(
                            executable: request.executable,
                            arguments: request.arguments,
                            timeout: request.timeout,
                            handle: handle,
                            environment: request.environment,
                            workingDirectory: request.workingDirectory)
                        continuation.resume(returning: ProcessResult(
                            exitCode: outcome.exitCode,
                            timedOut: outcome.timedOut,
                            cancelled: outcome.cancelled,
                            stdout: outcome.stdout,
                            stderr: outcome.stderr))
                    } catch {
                        // Only a failed `Process.run()` reaches here, wrapped
                        // as `LLMRunnerError.launchFailed`; unwrap it so the
                        // banner does not call the user's script "the LLM CLI".
                        var underlying = error
                        if case LLMRunnerError.launchFailed(let inner) = error { underlying = inner }
                        let ns = underlying as NSError
                        continuation.resume(returning: ProcessResult(
                            exitCode: -1,
                            launchFailure: underlying.localizedDescription,
                            launchFailureCode: "\(ns.domain) \(ns.code)"))
                    }
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }
}
