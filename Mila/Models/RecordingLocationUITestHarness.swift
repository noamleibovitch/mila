#if DEBUG
import Foundation

/// Deterministic, bounded slow-copy I/O seam for the folder-change NATIVE UI
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
/// - It pauses only on the detached copy worker (never the main actor) and
///   only through bounded `Thread.sleep` calls (0.4 s + 11 s max per instance,
///   under the 12 s cap). There is no continuation and no unbounded wait.
/// - The per-instance `NSLock` counter means the long pause runs once per
///   harness instance; there is no global state, so a second copy in the same
///   process is unaffected unless it builds its own harness.
/// - The pause is placed on the second full 1 MiB chunk, after an earlier
///   chunk was written, so the coordinator's throttled progress publisher has
///   real copied bytes to show before the test cancels or quits.
/// - `nil`/production/Release never construct this type; `MilaApp` references
///   it only inside `#if DEBUG` and only for `--ui-test-folder-scenario=slow-copy`.
final class RecordingLocationUITestHarness: @unchecked Sendable {
    /// The copy worker reads in exactly this block size.
    private static let fullChunk = 1_048_576

    private let lock = NSLock()
    private var fullChunks = 0
    private let warmup: TimeInterval
    private let pause: TimeInterval

    init(warmup: TimeInterval = 0.4, pause: TimeInterval = 11.0) {
        self.warmup = max(0, warmup)
        self.pause = max(0, pause)
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
        // Let the coordinator publish the preceding chunk's real progress at
        // its 4 Hz cadence before the long pause, so the native test observes
        // byte progress rather than only the copying phase.
        if block == 1 {
            Thread.sleep(forTimeInterval: warmup)
        }
        if block == 2 {
            Thread.sleep(forTimeInterval: pause)
        }
    }
}
#endif
