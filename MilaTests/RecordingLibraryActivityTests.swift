import XCTest
@testable import Mila

@MainActor
final class RecordingLibraryActivityTests: XCTestCase {
    func test_copy_snapshot_is_invalidated_even_when_worker_finishes_without_writing() throws {
        let activity = RecordingLibraryActivity()
        let before = activity.snapshot
        let worker = try XCTUnwrap(activity.beginWork())
        activity.finishWork(worker)
        XCTAssertEqual(activity.snapshot.outstandingCount, 0)
        XCTAssertThrowsError(try activity.performCommit(ifUnchanged: before) { _ in
            XCTFail("A copy taken before admitted work must not activate")
        }) { XCTAssertEqual($0 as? RecordingLibraryActivity.CommitError, .changed) }
    }

    func test_cancelled_worker_stays_busy_until_its_actual_cleanup_finishes() throws {
        let activity = RecordingLibraryActivity()
        let worker = try XCTUnwrap(activity.beginWork())
        // A UI cancellation clears no accounting. The token remains held while
        // a detached writer or child-process cleanup is still alive.
        let whileCleaningUp = activity.snapshot
        XCTAssertThrowsError(try activity.performCommit(ifUnchanged: whileCleaningUp) { _ in
            XCTFail("Canceled but unwinding I/O must block activation")
        }) { XCTAssertEqual($0 as? RecordingLibraryActivity.CommitError, .busy) }
        activity.finishWork(worker)
        XCTAssertNoThrow(try activity.performCommit(ifUnchanged: activity.snapshot) { _ in })
    }

    func test_duplicate_old_completion_cannot_retire_a_new_worker() throws {
        let activity = RecordingLibraryActivity()
        let first = try XCTUnwrap(activity.beginWork())
        activity.finishWork(first)
        let second = try XCTUnwrap(activity.beginWork())
        activity.finishWork(first)
        XCTAssertEqual(activity.snapshot.outstandingCount, 1)
        activity.finishWork(second)
        XCTAssertEqual(activity.snapshot.outstandingCount, 0)
    }

    func test_synchronous_subscriber_reentrancy_cannot_start_work_or_mutate_during_flip() throws {
        let activity = RecordingLibraryActivity()
        try activity.performCommit(ifUnchanged: activity.snapshot) { context in
            XCTAssertTrue(activity.isCommitting)
            XCTAssertNil(activity.beginWork())
            XCTAssertFalse(activity.noteMutation(in: context))
            XCTAssertThrowsError(try activity.performCommit(ifUnchanged: activity.snapshot) { _ in
                XCTFail("A synchronous subscriber must not reenter activation")
            }) { XCTAssertEqual($0 as? RecordingLibraryActivity.CommitError, .busy) }
        }
        XCTAssertFalse(activity.isCommitting)
        XCTAssertNotNil(activity.beginWork())
    }

    func test_failed_commit_releases_guard_but_never_reuses_previous_context() throws {
        enum Failure: Error { case injected }
        let activity = RecordingLibraryActivity()
        let original = activity.context
        XCTAssertThrowsError(try activity.performCommit(ifUnchanged: activity.snapshot) { _ in
            throw Failure.injected
        })
        XCTAssertFalse(activity.isCommitting)
        XCTAssertFalse(activity.isCurrent(original))
        XCTAssertFalse(activity.noteMutation(in: original))
        let intermediate = activity.context
        try activity.performCommit(ifUnchanged: activity.snapshot) { _ in }
        XCTAssertFalse(activity.isCurrent(intermediate))
        XCTAssertFalse(activity.isCurrent(original))
    }

    func test_failed_or_reverted_source_edit_still_invalidates_copied_snapshot() throws {
        let activity = RecordingLibraryActivity()
        let before = activity.snapshot
        XCTAssertTrue(activity.noteMutation(in: activity.context))
        // Disk or UI values may later return to their old values. The admission
        // revision must not, so equality of bytes alone cannot authorize flip.
        XCTAssertThrowsError(try activity.performCommit(ifUnchanged: before) { _ in
            XCTFail("A changed-then-reverted source must invalidate the copy")
        }) { XCTAssertEqual($0 as? RecordingLibraryActivity.CommitError, .changed) }
    }
}

@MainActor
extension RecordingLibraryActivityTests {
    func test_work_ledger_counts_cancelled_or_replaced_work_until_settlement() {
        let ledger = RecordingLibraryWorkLedger(owner: "Test", reason: "busy")
        let first = ledger.begin()
        XCTAssertFalse(ledger.state.isIdle)
        // A canceled UI action does not finish the ticket; only the worker's
        // actual settlement does.
        XCTAssertFalse(ledger.state.isIdle)
        ledger.finish(first)
        XCTAssertTrue(ledger.state.isIdle)
        let before = ledger.generation
        let second = ledger.begin()
        ledger.finish(second)
        XCTAssertGreaterThan(ledger.generation, before,
                             "A job that starts and finishes must still advance the generation")
    }

    func test_readiness_aggregate_reports_first_blocker_and_is_snapshot_stable() {
        let first = RecordingLibraryWorkState.idle("A", generation: 4)
        let second = RecordingLibraryWorkState.busy("B", "still running", generation: 9)
        let readiness = RecordingLibraryReadiness(providers: [{ first }, { second }])
        XCTAssertFalse(readiness.isIdle)
        XCTAssertEqual(readiness.latest.firstBlocker?.owner, "B")
        XCTAssertEqual(readiness.latest.firstBlocker?.generation, 9)
        readiness.refresh()
        XCTAssertEqual(readiness.latest.firstBlocker?.owner, "B")
    }
}
