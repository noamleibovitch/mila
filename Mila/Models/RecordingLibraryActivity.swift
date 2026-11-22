import Foundation

/// Accounts for admitted library work before a caller schedules its Task.
/// Cancellation does not finish a ticket: the worker retires it after all I/O
/// and completion callbacks have unwound. This is accounting, not a write lock.
/// Owners must still expose queued work and use the captured context at writes.
@MainActor
final class RecordingLibraryActivity {
    struct Context: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Codable, opaque handle for a `Context` that must travel outside the
    /// MainActor — chiefly the drag-and-drop payload. Possession of the token
    /// proves nothing; it only lets a drop ask whether the library it was
    /// dragged from is still current.
    struct ContextToken: Codable, Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    struct Ticket: Hashable, Sendable {
        let context: Context
        fileprivate let id: UUID
    }

    struct Snapshot: Equatable, Sendable {
        let context: Context
        let generation: UInt64
        let outstandingCount: Int
    }

    enum CommitError: Error, Equatable {
        case busy
        case changed
        case exhausted
    }

    private(set) var context = Context(id: UUID())
    private var generation: UInt64 = 0
    private var outstanding: Set<Ticket> = []
    private var committing = false

    var snapshot: Snapshot {
        Snapshot(context: context, generation: generation,
                 outstandingCount: outstanding.count)
    }

    var isCommitting: Bool { committing }

    var contextToken: ContextToken { ContextToken(rawValue: context.id) }

    /// nil means admission was refused. Callers must surface a busy outcome;
    /// they must not start work and later drop its completion.
    func beginWork() -> Ticket? {
        guard !committing, advanceGeneration() else { return nil }
        let ticket = Ticket(context: context, id: UUID())
        outstanding.insert(ticket)
        return ticket
    }

    /// Only the owning invocation can retire its ticket. Duplicate and stale
    /// completions cannot release another worker's reservation.
    func finishWork(_ ticket: Ticket) {
        outstanding.remove(ticket)
    }

    func isCurrent(_ captured: Context) -> Bool {
        captured == context
    }

    func isCurrent(_ token: ContextToken) -> Bool {
        token.rawValue == context.id
    }

    /// Count every attempted library mutation, including failed persistence.
    /// false is explicit refusal, not permission to discard an existing result.
    func noteMutation(in captured: Context) -> Bool {
        guard !committing, isCurrent(captured) else { return false }
        return advanceGeneration()
    }

    /// The coordinator calls this after off-main copy/hash and owner-idle
    /// checks. Its final lightweight filesystem checks and prepared activation
    /// run in the synchronous closure; an async operation cannot be supplied.
    /// Synchronous Combine subscribers also see the admission guard.
    func performCommit<T>(ifUnchanged expected: Snapshot,
                          operation: (Context) throws -> T) throws -> T {
        guard !committing, outstanding.isEmpty else { throw CommitError.busy }
        guard expected == snapshot else { throw CommitError.changed }
        guard advanceGeneration() else { throw CommitError.exhausted }
        committing = true
        // Even a failed attempt invalidates previously captured UI/work
        // contexts. Never restore an old epoch (switch-away-and-back ABA).
        context = Context(id: UUID())
        defer { committing = false }
        return try operation(context)
    }

    private func advanceGeneration() -> Bool {
        guard generation < UInt64.max else { return false }
        generation += 1
        return true
    }
}
