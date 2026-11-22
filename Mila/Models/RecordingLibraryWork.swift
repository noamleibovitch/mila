import Foundation
import Combine

/// Owner-local, read-only readiness. Every production writer exposes one of
/// these computed from its real private state (queued, running, canceled but
/// still unwinding, or cleanup). The migration coordinator never replaces
/// these flags with a global lease and never cancels the work.
struct RecordingLibraryWorkState: Equatable, Sendable {
    let owner: String
    let reason: String?
    /// Advances whenever an owner admits or retires work, so a job that starts
    /// and finishes between two reads still invalidates an earlier snapshot.
    let generation: UInt64

    var isIdle: Bool { reason == nil }

    static func idle(_ owner: String, generation: UInt64 = 0) -> RecordingLibraryWorkState {
        RecordingLibraryWorkState(owner: owner, reason: nil, generation: generation)
    }

    static func busy(_ owner: String, _ reason: String, generation: UInt64 = 0) -> RecordingLibraryWorkState {
        RecordingLibraryWorkState(owner: owner, reason: reason, generation: generation)
    }
}

@MainActor
protocol RecordingLibraryWorkProviding: AnyObject {
    var libraryWorkState: RecordingLibraryWorkState { get }
}

/// Full-lifetime accounting for a producer that has no exhaustive private
/// map, or whose map releases a slot before detached I/O / child cleanup has
/// settled. A ticket is admitted synchronously before `Task` creation, URL
/// allocation or the first `await`, and retired only after the last detached
/// I/O and completion callback. Canceled or replaced work keeps its ticket
/// until it actually ends.
@MainActor
final class RecordingLibraryWorkLedger {
    struct Ticket: Hashable, Sendable {
        fileprivate let id: UUID
    }

    let owner: String
    private(set) var outstanding: Set<Ticket> = []
    private(set) var generation: UInt64 = 0
    private var reason: String

    init(owner: String, reason: String) {
        self.owner = owner
        self.reason = reason
    }

    func begin() -> Ticket {
        let ticket = Ticket(id: UUID())
        outstanding.insert(ticket)
        if generation < UInt64.max { generation += 1 }
        return ticket
    }

    func finish(_ ticket: Ticket) {
        guard outstanding.remove(ticket) != nil else { return }
        if generation < UInt64.max { generation += 1 }
    }

    func updateReason(_ reason: String) { self.reason = reason }

    var state: RecordingLibraryWorkState {
        RecordingLibraryWorkState(owner: owner,
                                   reason: outstanding.isEmpty ? nil : reason,
                                   generation: generation)
    }
}

/// Reads each owner synchronously on the main actor. The coordinator calls it
/// at entry, after copying/publication and inside the final no-await commit.
@MainActor
final class RecordingLibraryReadiness: ObservableObject {
    struct Snapshot: Equatable {
        let states: [RecordingLibraryWorkState]
        var firstBlocker: RecordingLibraryWorkState? { states.first { !$0.isIdle } }
        var isIdle: Bool { firstBlocker == nil }
    }

    /// Settings polls this while it is visible. It is never a high-frequency
    /// App-level publish: the value changes only when an owner's aggregate
    /// readiness actually changes.
    @Published private(set) var latest = Snapshot(states: [])
    private var providers: [() -> RecordingLibraryWorkState] = []

    init(providers: [() -> RecordingLibraryWorkState] = []) {
        self.providers = providers
        latest = Snapshot(states: providers.map { $0() })
    }

    func refresh() {
        let next = snapshot()
        if next != latest { latest = next }
    }

    func add(_ provider: @escaping () -> RecordingLibraryWorkState) {
        providers.append(provider)
        refresh()
    }

    func add(_ owner: RecordingLibraryWorkProviding) {
        providers.append { [weak owner] in owner?.libraryWorkState ?? .idle("released owner") }
        refresh()
    }

    func snapshot() -> Snapshot {
        Snapshot(states: providers.map { $0() })
    }

    var isIdle: Bool { snapshot().isIdle }

    var blockerText: String? { latest.firstBlocker?.reason }
}

/// Launch crash-recovery work: WAV header repair, bulk status updates and the
/// transcription re-enqueue. Registered before the first `await` and retired
/// after the whole sweep, so opening the folder chooser cannot race it.
@MainActor
final class StartupRecoveryWork: ObservableObject {
    private let ledger = RecordingLibraryWorkLedger(
        owner: "Launch recovery", reason: "Mila is still recovering recordings from the last launch.")
    private var ticket: RecordingLibraryWorkLedger.Ticket?

    var libraryWorkState: RecordingLibraryWorkState { ledger.state }
    var isActive: Bool { ticket != nil }

    func begin() {
        if ticket == nil { ticket = ledger.begin() }
    }

    func finish() {
        if let ticket { ledger.finish(ticket); self.ticket = nil }
    }
}
