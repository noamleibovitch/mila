#if DEBUG
import Foundation

/// Deterministic, bounded held-copy I/O seam for the folder-change NATIVE UI
/// verification only.
///
/// It is constructed exclusively by `MilaApp`'s DEBUG folder-scenario parser
/// after every UI-test isolation flag (clean store, UUID-owned storage suite,
/// seeded synthetic recording, scenario value and a validated clean root) is
/// present. The coordinator receives its closure as the existing `chunkWrite`
/// seam and forwards it to the detached copy worker.
///
/// Contract:
/// - It writes the REAL bytes it is handed, so the stage contains genuine
///   partial data and the normal hash/length checks still run.
/// - It runs only on the detached copy worker, never the main actor, and only
///   through bounded `Thread.sleep` calls. The first full 1 MiB chunk gets a
///   short warmup so the main actor has room to publish that real copied
///   prefix while the gate then holds the worker.
/// - After the second full 1 MiB chunk it holds the worker on a bounded,
///   file-signalled gate: it polls for ONE release marker named inside the
///   already-validated `Mila-UITest-<UUID>` clean root. The UI test creates
///   that marker only when it performs the real interrupting action (Cancel,
///   Keep copying or Stop and quit), or from its own cleanup on a failed
///   assertion. The gate never waits longer than `releaseTimeout` (45 s
///   default) and then lets the copy proceed, so a missed marker degrades to a
///   visible downstream failure instead of a hang.
/// - The per-instance `NSLock` counter means the gate runs once per harness
///   instance; there is no global state, so a second copy in the same process
///   is unaffected unless it builds its own harness.
/// - The gate is placed after a real, published first chunk so a native test
///   observes nonzero byte progress that persists until it acts. This keeps
///   the observable interruption window open for as long as the UI queries
///   need, instead of expiring on a fixed wall-clock pause.
/// - `nil`/production/Release never construct this type; `MilaApp` references
///   it only inside `#if DEBUG` and only for `--ui-test-folder-scenario=slow-copy`.
final class RecordingLocationUITestHarness: @unchecked Sendable {
    /// The copy worker reads in exactly this block size.
    private static let fullChunk = 1_048_576

    /// The single fixed marker name the UI test creates inside its validated
    /// clean root. It is never read from or written to any other location.
    static let releaseMarkerName = "Mila-UITest-copy-gate-release"

    private let lock = NSLock()
    private var fullChunks = 0
    private let warmup: TimeInterval
    private let releaseTimeout: TimeInterval
    private let releaseMarker: URL

    init(releaseRoot: URL,
         warmup: TimeInterval = 0.4,
         releaseTimeout: TimeInterval = 45) {
        self.releaseMarker = releaseRoot
            .appendingPathComponent(Self.releaseMarkerName, isDirectory: false)
        self.warmup = max(0, warmup)
        self.releaseTimeout = max(0, releaseTimeout)
    }

    /// The escaping seam handed to `RecordingLocationCoordinator(chunkWrite:)`.
    /// The closure strongly retains this harness for the coordinator's lifetime.
    var chunkWrite: @Sendable (FileHandle, Data) throws -> Void {
        { [self] handle, data in try self.writeChunk(handle, data) }
    }

    private func writeChunk(_ handle: FileHandle, _ data: Data) throws {
        try handle.write(contentsOf: data)
        let block: Int? = {
            lock.lock()
            defer { lock.unlock() }
            guard data.count == Self.fullChunk else { return nil }
            fullChunks += 1
            return fullChunks
        }()
        // Give the main actor a brief warmup (more than one 4 Hz throttle
        // interval) before the long gate; the first chunk's real byte progress
        // is scheduled right after this and stays observable because the gate
        // holds the worker until the UI test acts.
        if block == 1 {
            Thread.sleep(forTimeInterval: warmup)
        }
        // Hold after the second real chunk until the UI test performs the
        // interrupting action.
        if block == 2 {
            waitForRelease()
        }
    }

    /// Bounded poll on the detached copy worker only. Never called on the main
    /// actor. Returns when the marker appears or after `releaseTimeout`; there
    /// is no continuation and no unbounded wait.
    private func waitForRelease() {
        let deadline = Date().addingTimeInterval(releaseTimeout)
        while !FileManager.default.fileExists(atPath: releaseMarker.path) {
            if Date() >= deadline { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
#endif
