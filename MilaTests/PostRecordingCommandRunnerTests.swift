import XCTest
@testable import Mila

/// `PostRecordingCommandRunner`: the sequencing it shares with
/// `ObsidianExporter` (pending gate, discard tombstone, summarizer hook), what
/// it hands the command, and — against real child processes — that the
/// command is killed on timeout and when its recording is deleted mid-run.
@MainActor
final class PostRecordingCommandRunnerTests: XCTestCase {

    /// Records what the runner asked to launch, in place of launching it.
    private final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [PostRecordingCommandRunner.ProcessRequest] = []
        private var running = 0
        private var peak = 0

        var all: [PostRecordingCommandRunner.ProcessRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
        var peakConcurrency: Int {
            lock.lock(); defer { lock.unlock() }
            return peak
        }
        func begin(_ request: PostRecordingCommandRunner.ProcessRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            running += 1
            peak = max(peak, running)
        }
        func end() {
            lock.lock(); defer { lock.unlock() }
            running -= 1
        }
    }

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var suiteNames: [String] = []
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var settings: PostRecordingCommandSettings!
    private var runner: PostRecordingCommandRunner!
    private var summarizer: RecordingSummarizer!
    private var launches: Launches!
    private var banners: [(message: String, isError: Bool)] = []
    private var script: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "MilaPostCommandRunner")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot.appendingPathComponent("AppSupport", isDirectory: true))

        let llmSuite = "PostCommandRunner.llm.\(UUID())"
        let liveSuite = "PostCommandRunner.live.\(UUID())"
        let commandSuite = "PostCommandRunner.command.\(UUID())"
        suiteNames = [llmSuite, liveSuite, commandSuite]
        llm = LLMSettings(defaults: UserDefaults(suiteName: llmSuite)!)
        llm.tool = .claude
        liveAI = LiveAISettings(defaults: UserDefaults(suiteName: liveSuite)!)
        liveAI.model = ""

        script = try writeScript("hook.sh", body: "exit 0")
        settings = PostRecordingCommandSettings(defaults: UserDefaults(suiteName: commandSuite)!)
        settings.enabled = true
        settings.command = "\(script.path) --dest 'My Notes'"

        launches = Launches()
        banners = []
        useStubbedLaunch()
        useLLM { "A tidy summary." }
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func writeScript(_ name: String, body: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A runner that records launches instead of spawning. `result` is what
    /// every launch reports; `hold` keeps each one "running" for that long.
    private func useStubbedLaunch(result: PostRecordingCommandRunner.ProcessResult = .init(),
                                  hold: UInt64 = 0) {
        let launches = self.launches!
        makeRunner { request in
            launches.begin(request)
            if hold > 0 { try? await Task.sleep(nanoseconds: hold) }
            launches.end()
            return result
        }
    }

    /// A runner that really spawns the command.
    private func useRealLaunch() {
        makeRunner { await PostRecordingCommandRunner.spawn($0) }
    }

    private func makeRunner(_ execute: @escaping PostRecordingCommandRunner.Execute) {
        runner = PostRecordingCommandRunner(store: store, settings: settings, execute: execute)
        runner.postStatus = { [weak self] message, isError in
            self?.banners.append((message, isError))
        }
        wireHook()
    }

    private func useLLM(_ answer: @escaping @MainActor () throws -> String) {
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
                                         runLLM: { _, _, _, _, _, _, _, _, _, _, _ in try answer() })
        wireHook()
    }

    /// The hook exactly as `MilaApp` wires it.
    private func wireHook() {
        runner?.awaitSummarySettled = { [weak summarizer] id in
            while summarizer?.isSummarizing(id) == true {
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { return }
            }
        }
        summarizer?.onSummaryFinished = { [weak runner] rec in
            runner?.runIfPending(rec)
        }
    }

    @discardableResult
    private func addRecording(title: String = "Rec",
                              fullText: String = "some transcript") -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: title)
        try? Data("x".utf8).write(to: audioURL)
        let rec = Recording(title: title, duration: 30, source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            status: .completed, fullText: fullText)
        store.add(rec)
        try? Data("1\n".utf8).write(to: store.subtitleURL(for: rec))
        return rec
    }

    /// What `onTranscriptionCompleted` does for a fresh recording.
    private func complete(_ rec: Recording) async {
        if settings.isReady { runner.markPending(rec.id) }
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)
        await runner.awaitIdle()
    }

    private func handoff(for rec: Recording) throws -> PostRecordingHandoff {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PostRecordingHandoff.self,
                                  from: Data(contentsOf: runner.handoffURL(for: rec.id)))
    }

    // MARK: - Sequencing

    func test_fresh_recording_runs_once_after_its_summary_lands() async throws {
        let rec = addRecording()
        await complete(rec)

        XCTAssertEqual(launches.all.count, 1)
        XCTAssertEqual(try handoff(for: rec).summary, "A tidy summary.",
                       "the handoff is written from the row AFTER the summary landed")
        XCTAssertFalse(runner.isPending(rec.id), "the mark is consumed")
        XCTAssertEqual(banners.last?.message, "Post-recording command finished.")
        XCTAssertEqual(banners.last?.isError, false)

        // A later summary for the same recording does not run it again.
        summarizer.regenerate(try XCTUnwrap(store.recordings.first))
        await summarizer.awaitInFlight(rec.id)
        await runner.awaitIdle()
        XCTAssertEqual(launches.all.count, 1)
    }

    /// The launch-time backfill sweep summarizes recordings nobody marked.
    func test_only_a_captured_recording_is_marked_by_the_batch_hook() async throws {
        let imported = addRecording()
        runner.markPendingIfCaptured(imported.id)
        XCTAssertFalse(runner.isPending(imported.id), "an import or a recovered orphan is not a finished meeting")

        let captured = addRecording()
        runner.noteCaptured(captured.id)
        runner.markPendingIfCaptured(captured.id)
        XCTAssertTrue(runner.isPending(captured.id))
    }

    func test_unmarked_summary_never_runs_the_command() async throws {
        let rec = addRecording()
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)
        await runner.awaitIdle()

        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.handoffURL(for: rec.id).path))
    }

    func test_runs_when_summaries_are_off() async throws {
        llm.summaryEnabled = false
        let rec = addRecording()
        await complete(rec)

        XCTAssertEqual(launches.all.count, 1)
        XCTAssertNil(try handoff(for: rec).summary)
    }

    func test_runs_when_no_llm_is_configured() async throws {
        llm.tool = .none
        let rec = addRecording()
        await complete(rec)

        XCTAssertEqual(launches.all.count, 1)
    }

    func test_runs_when_the_summary_fails() async throws {
        struct StubFailure: Error {}
        useLLM { throw StubFailure() }
        let rec = addRecording()
        await complete(rec)

        XCTAssertEqual(launches.all.count, 1)
        XCTAssertNil(try handoff(for: rec).summary)
    }

    func test_nothing_is_marked_or_run_while_the_hook_is_off() async throws {
        settings.enabled = false
        let rec = addRecording()
        await complete(rec)
        XCTAssertTrue(launches.all.isEmpty)

        // Marked while on, switched off before the summary landed: the run
        // re-checks the settings and stands down.
        settings.enabled = true
        runner.markPending(rec.id)
        settings.enabled = false
        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)
        await runner.awaitIdle()
        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.handoffURL(for: rec.id).path),
                       "no handoff is written for a run that does not happen")
    }

    func test_captured_recording_without_summary_is_automatically_run_only_once() async throws {
        llm.summaryEnabled = false
        let rec = addRecording()
        runner.noteCaptured(rec.id)
        runner.markPendingIfCaptured(rec.id)
        summarizer.summarizeIfNeeded(rec)
        await runner.awaitIdle()
        XCTAssertEqual(launches.all.count, 1)
        // The same callback shape is used by a re-transcription with no
        // stored summary. It must not gain fresh-capture eligibility.
        runner.markPendingIfCaptured(rec.id)
        summarizer.summarizeIfNeeded(rec)
        await runner.awaitIdle()
        XCTAssertEqual(launches.all.count, 1)
    }

    func test_disabled_capture_is_not_rearmed_by_later_retranscription() {
        let rec = addRecording()
        runner.noteCaptured(rec.id)
        runner.markPendingIfCaptured(rec.id, enabled: false)
        runner.markPendingIfCaptured(rec.id, enabled: true)
        XCTAssertFalse(runner.isPending(rec.id))
    }

    func test_manual_run_waits_for_summary_and_coalesces_the_pending_automatic_run() async throws {
        let gate = TestGate()
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _ in
                await gate.wait()
                return "The final summary"
            })
        wireHook()
        let rec = addRecording()
        runner.markPending(rec.id)
        summarizer.summarizeIfNeeded(rec)
        runner.run(recordingID: rec.id, trigger: .manual)
        await Task.yield()
        XCTAssertTrue(launches.all.isEmpty)
        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await runner.awaitIdle()
        XCTAssertEqual(launches.all.count, 1)
        XCTAssertEqual(try handoff(for: rec).summary, "The final summary")
    }

    func test_shutdown_cancels_a_summary_wait_and_closes_admission() async throws {
        let gate = TestGate()
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _ in
                await gate.wait()
                return "summary"
            })
        wireHook()
        let rec = addRecording()
        summarizer.summarizeIfNeeded(rec)
        runner.run(recordingID: rec.id, trigger: .manual)
        await Task.yield()
        await runner.shutdown()
        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertFalse(runner.run(recordingID: rec.id, trigger: .manual))
        runner.markPending(rec.id)
        XCTAssertFalse(runner.isPending(rec.id))
        gate.open()
        await summarizer.awaitInFlight(rec.id)
    }

    // MARK: - Deleted stays deleted

    /// `finalizeTail` outlives a discard and ends by marking the id pending.
    func test_a_discarded_recording_cannot_be_re_armed() async throws {
        let rec = addRecording()
        store.permanentlyDelete(rec)

        runner.markPending(rec.id)
        XCTAssertFalse(runner.isPending(rec.id))
        runner.runIfPending(rec)
        XCTAssertFalse(runner.run(recordingID: rec.id, trigger: .manual))
        await runner.awaitIdle()
        XCTAssertTrue(launches.all.isEmpty)
    }

    /// The rename sheet's Discard for a row that is already out of the store.
    func test_discard_tombstones_an_id_the_store_never_reported() async throws {
        let ghost = UUID()
        runner.markPending(ghost)
        runner.discard(ghost)
        XCTAssertFalse(runner.isPending(ghost))
        runner.markPending(ghost)
        XCTAssertFalse(runner.isPending(ghost))
    }

    func test_a_trashed_recording_does_not_run() async throws {
        let rec = addRecording()
        runner.markPending(rec.id)
        store.softDelete(rec)
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)
        await runner.awaitIdle()

        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.handoffURL(for: rec.id).path))
    }

    func test_permanent_delete_removes_the_handoff_file() async throws {
        let rec = addRecording()
        await complete(rec)
        let file = runner.handoffURL(for: rec.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.softDelete(rec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Recently Deleted is recoverable, so the handoff stays with the audio")
        store.emptyTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the handoff repeats the title and summary the user just deleted")
    }

    // MARK: - What the command is handed

    func test_request_carries_the_handoff_last_and_the_environment() async throws {
        settings.timeoutSeconds = 45
        let rec = addRecording(title: "Client call; rm -rf ~")
        await complete(rec)

        let request = try XCTUnwrap(launches.all.first)
        let handoffPath = runner.handoffURL(for: rec.id).path
        XCTAssertEqual(request.executable.path, script.path)
        XCTAssertEqual(request.arguments, ["--dest", "My Notes", handoffPath],
                       "the user's arguments, then the handoff path, and nothing from the recording")
        XCTAssertEqual(request.timeout, 45)

        XCTAssertEqual(request.environment["MILA_RECORDING_ID"], rec.id.uuidString)
        XCTAssertEqual(request.environment["MILA_HANDOFF"], handoffPath)
        XCTAssertEqual(request.environment["MILA_SRT"], store.subtitleURL(for: rec).path)
        XCTAssertEqual(request.environment["MILA_TXT"], store.transcriptURL(for: rec).path)
        XCTAssertEqual(request.environment["MILA_AUDIO"], store.audioURL(for: rec).path)
        XCTAssertNotNil(request.environment["PATH"])

        // cwd: a directory under Mila's own root, never the user's home.
        XCTAssertEqual(request.workingDirectory, runner.workingDirectory)
        XCTAssertTrue(request.workingDirectory.path.hasPrefix(store.originalRootDirectory.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.workingDirectory.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func test_a_missing_sidecar_is_an_unset_variable() async throws {
        let rec = addRecording()
        try FileManager.default.removeItem(at: store.subtitleURL(for: rec))
        await complete(rec)

        let request = try XCTUnwrap(launches.all.first)
        XCTAssertNil(request.environment["MILA_SRT"])
        XCTAssertNil(try handoff(for: rec).files.srt)
    }

    func test_handoff_is_owner_only_and_under_the_store_root() async throws {
        let rec = addRecording()
        await complete(rec)

        let file = runner.handoffURL(for: rec.id)
        XCTAssertEqual(file.deletingLastPathComponent(),
                       store.originalRootDirectory.appendingPathComponent("handoff", isDirectory: true))
        XCTAssertEqual(file.lastPathComponent, "\(rec.id.uuidString).json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        let dirMode = try FileManager.default
            .attributesOfItem(atPath: runner.handoffDirectory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue, 0o700)
    }

    func test_only_the_newest_handoffs_are_kept() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runner.handoffDirectory, withIntermediateDirectories: true)
        // Thirty old handoffs, oldest first, plus a file that is not ours.
        var old: [URL] = []
        for index in 0..<30 {
            let url = runner.handoffURL(for: UUID())
            try Data("{}".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index) - 10_000)],
                                 ofItemAtPath: url.path)
            old.append(url)
        }
        let stranger = runner.handoffDirectory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: stranger)

        let rec = addRecording()
        await complete(rec)

        let kept = try fm.contentsOfDirectory(atPath: runner.handoffDirectory.path)
            .filter { UUID(uuidString: ($0 as NSString).deletingPathExtension) != nil }
        XCTAssertEqual(kept.count, PostRecordingCommandRunner.maxHandoffFiles)
        XCTAssertTrue(fm.fileExists(atPath: runner.handoffURL(for: rec.id).path),
                      "the handoff just written is the newest")
        XCTAssertFalse(fm.fileExists(atPath: old[0].path), "the oldest went first")
        XCTAssertTrue(fm.fileExists(atPath: old[29].path))
        XCTAssertTrue(fm.fileExists(atPath: stranger.path),
                      "a file that is not <uuid>.json is not Mila's to delete")
    }

    // MARK: - Queue and manual runs

    func test_runs_are_serial() async throws {
        useStubbedLaunch(hold: 50_000_000)
        let recordings = (0..<4).map { addRecording(title: "Rec \($0)") }
        for rec in recordings {
            XCTAssertTrue(runner.run(recordingID: rec.id, trigger: .automatic))
        }
        await runner.awaitIdle()

        XCTAssertEqual(launches.all.count, 4)
        XCTAssertEqual(launches.peakConcurrency, 1)
        XCTAssertEqual(launches.all.map { $0.environment["MILA_RECORDING_ID"] },
                       recordings.map(\.id.uuidString), "first queued, first run")
    }

    func test_manual_run_reruns_a_finished_recording_and_refuses_a_duplicate() async throws {
        useStubbedLaunch(hold: 50_000_000)
        let rec = addRecording()
        XCTAssertTrue(runner.run(recordingID: rec.id, trigger: .manual))
        XCTAssertTrue(runner.isRunning(rec.id))
        XCTAssertFalse(runner.run(recordingID: rec.id, trigger: .manual),
                       "one run per recording at a time")
        await runner.awaitIdle()
        XCTAssertFalse(runner.isRunning(rec.id))

        XCTAssertTrue(runner.run(recordingID: rec.id, trigger: .manual))
        await runner.awaitIdle()
        XCTAssertEqual(launches.all.count, 2)
    }

    func test_manual_run_says_so_when_the_command_is_not_ready() async throws {
        let rec = addRecording()
        settings.command = tempRoot.appendingPathComponent("gone.sh").path
        runner.run(recordingID: rec.id, trigger: .manual)
        await runner.awaitIdle()

        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertEqual(banners.last?.isError, true)
        XCTAssertEqual(runner.lastRun?.isError, true)
    }

    // MARK: - Status messages

    func test_status_messages() {
        typealias Result = PostRecordingCommandRunner.ProcessResult
        let ok = PostRecordingCommandRunner.statusMessage(for: Result(), timeout: 600)
        XCTAssertEqual(ok.message, "Post-recording command finished.")
        XCTAssertFalse(ok.isError)

        let failed = PostRecordingCommandRunner.statusMessage(
            for: Result(exitCode: 3, stdout: "ignored", stderr: "\n  cp: no such file\nmore\n"),
            timeout: 600)
        XCTAssertEqual(failed.message, "Post-recording command failed (exit 3): cp: no such file")
        XCTAssertTrue(failed.isError)

        let quiet = PostRecordingCommandRunner.statusMessage(for: Result(exitCode: 1), timeout: 600)
        XCTAssertEqual(quiet.message, "Post-recording command failed (exit 1)")

        let timedOut = PostRecordingCommandRunner.statusMessage(
            for: Result(exitCode: -1, timedOut: true), timeout: 30)
        XCTAssertEqual(timedOut.message, "Post-recording command was stopped after 30s without finishing.")
        XCTAssertTrue(timedOut.isError)

        let noLaunch = PostRecordingCommandRunner.statusMessage(
            for: Result(exitCode: -1, launchFailure: "No such file"), timeout: 600)
        XCTAssertEqual(noLaunch.message, "Post-recording command couldn't start: No such file")
    }

    // MARK: - Real child processes

    func test_real_command_receives_argv_environment_and_cwd() async throws {
        let out = tempRoot.appendingPathComponent("out.txt")
        script = try writeScript("report.sh", body: """
            {
              echo "argc=$#"
              echo "first=$1"
              for last; do :; done
              echo "last=$last"
              echo "id=$MILA_RECORDING_ID"
              echo "handoff=$MILA_HANDOFF"
              echo "srt=$MILA_SRT"
              echo "cwd=$(pwd -P)"
              echo "summary=$(grep -c 'A tidy summary' "$MILA_HANDOFF")"
            } > '\(out.path)'
            echo "chatty stdout"
            echo "chatty stderr" >&2
            """)
        settings.command = "\(script.path) 'two words'"
        useRealLaunch()
        let rec = addRecording()
        await complete(rec)

        // `pwd -P` spells the temp directory `/private/var/…`; the URL does not.
        let lines = try String(contentsOf: out, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .map { $0.replacingOccurrences(of: "cwd=/private/", with: "cwd=/") }
        let handoffPath = runner.handoffURL(for: rec.id).path
        XCTAssertEqual(lines, [
            "argc=2",
            "first=two words",
            "last=\(handoffPath)",
            "id=\(rec.id.uuidString)",
            "handoff=\(handoffPath)",
            "srt=\(store.subtitleURL(for: rec).path)",
            "cwd=\(runner.workingDirectory.path)",
            "summary=1"
        ])
        XCTAssertEqual(banners.last?.message, "Post-recording command finished.")
    }

    func test_real_command_failure_reports_exit_code_and_stderr() async throws {
        script = try writeScript("fail.sh", body: "echo 'disk is full' >&2\nexit 7")
        settings.command = script.path
        useRealLaunch()
        await complete(addRecording())

        XCTAssertEqual(banners.last?.message, "Post-recording command failed (exit 7): disk is full")
        XCTAssertEqual(banners.last?.isError, true)
    }

    func test_real_command_is_terminated_at_the_timeout() async throws {
        let survived = tempRoot.appendingPathComponent("survived")
        script = try writeScript("slow.sh", body: "sleep 30\ntouch '\(survived.path)'")
        let request = PostRecordingCommandRunner.ProcessRequest(
            executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: tempRoot, timeout: 1)

        let started = Date()
        let result = await PostRecordingCommandRunner.spawn(request)

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "killed, not waited out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: survived.path))
    }

    func test_spawn_reports_a_command_that_cannot_launch() async throws {
        let request = PostRecordingCommandRunner.ProcessRequest(
            executable: tempRoot.appendingPathComponent("missing.sh"), arguments: [],
            environment: [:], workingDirectory: tempRoot, timeout: 5)
        let result = await PostRecordingCommandRunner.spawn(request)

        XCTAssertNotNil(result.launchFailure)
        XCTAssertNotNil(result.launchFailureCode)
        XCTAssertFalse(result.timedOut)
    }

    func test_timeout_does_not_resume_a_shell_past_its_foreground_child() async throws {
        let survived = tempRoot.appendingPathComponent("survived")
        let ready = tempRoot.appendingPathComponent("ready")
        // A harmless TERM trap makes the ordering deterministic: signalling
        // the group kills sleep, wakes the shell, and it runs the next line.
        // Stopping the leader first must prevent that continuation.
        script = try writeScript("foreground.sh", body: """
            trap ':' TERM
            touch '\(ready.path)'
            sleep 30
            touch '\(survived.path)'
            """)
        let request = PostRecordingCommandRunner.ProcessRequest(
            executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: tempRoot, timeout: 1)
        let started = Date()
        let result = await PostRecordingCommandRunner.spawn(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "fixture must install its trap before timeout")
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: survived.path))
    }

    /// Delete while the command is running: it is killed, its handoff goes,
    /// and there is no banner — the cancellation was the user's.
    func test_deleting_the_recording_mid_run_kills_the_command() async throws {
        let startedMarker = tempRoot.appendingPathComponent("started")
        let survived = tempRoot.appendingPathComponent("survived")
        script = try writeScript("slow.sh", body: """
            touch '\(startedMarker.path)'
            sleep 30
            touch '\(survived.path)'
            """)
        settings.command = script.path
        useRealLaunch()
        let rec = addRecording()
        runner.markPending(rec.id)
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: startedMarker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedMarker.path), "the command started")
        XCTAssertTrue(runner.isRunning(rec.id))

        let deletedAt = Date()
        store.permanentlyDelete(try XCTUnwrap(store.recordings.first))
        XCTAssertFalse(runner.isRunning(rec.id))
        await runner.awaitIdle()

        XCTAssertLessThan(Date().timeIntervalSince(deletedAt), 20, "killed, not waited out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: survived.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.handoffURL(for: rec.id).path))
        XCTAssertTrue(banners.isEmpty, "a deliberate cancel posts nothing: \(banners)")
    }

    func test_shutdown_kills_running_child_and_never_starts_queued_commands() async throws {
        let started = tempRoot.appendingPathComponent("started")
        let survived = tempRoot.appendingPathComponent("survived")
        script = try writeScript("shutdown.sh", body: """
            echo "$MILA_RECORDING_ID" >> '\(started.path)'
            sleep 30
            touch '\(survived.path)'
            """)
        settings.command = script.path
        useRealLaunch()
        let first = addRecording(title: "First")
        let second = addRecording(title: "Second")
        runner.run(recordingID: first.id, trigger: .automatic)
        runner.run(recordingID: second.id, trigger: .automatic)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let stoppedAt = Date()
        await runner.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: survived.path))
        let ids = try String(contentsOf: started, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(ids, [first.id.uuidString])
    }

    func test_trashing_the_recording_mid_run_kills_the_command() async throws {
        let startedMarker = tempRoot.appendingPathComponent("started")
        let survived = tempRoot.appendingPathComponent("survived")
        script = try writeScript("slow.sh", body: """
            touch '\(startedMarker.path)'
            sleep 30
            touch '\(survived.path)'
            """)
        settings.command = script.path
        useRealLaunch()
        let rec = addRecording()
        runner.run(recordingID: rec.id, trigger: .automatic)

        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: startedMarker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        store.softDelete(rec)
        await runner.awaitIdle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: survived.path))
        XCTAssertTrue(banners.isEmpty)
        // Not tombstoned: restored, it can be run by hand.
        store.restore(try XCTUnwrap(store.recordings.first))
        XCTAssertTrue(runner.run(recordingID: rec.id, trigger: .manual))
        store.permanentlyDelete(try XCTUnwrap(store.recordings.first))
        await runner.awaitIdle()
    }
}
