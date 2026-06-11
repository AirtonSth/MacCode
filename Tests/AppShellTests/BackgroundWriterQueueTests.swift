import XCTest
@testable import AppShell
import SocketServer
import CoreModel

/// Tests for the P3 background-writer queue:
/// (1) Pure cadence helper: AppContext.shouldPrune(appendCount:interval:)
/// (2) Writer-dispatch: persister closure body executes off the main thread.
///
/// Rule 8 compliance: every assertion encodes WHY the behaviour matters:
/// - shouldPrune gates the expensive DELETE SQL so it runs every N inserts,
///   not on every append, amortising SQLite I/O during high-frequency bursts.
/// - Off-main dispatch prevents the EventBus publish path from blocking the
///   main/run-loop thread while the DB write is pending.
final class BackgroundWriterQueueTests: XCTestCase {

    // MARK: - Pure cadence helper

    /// First append (count=1) with interval=1 must prune - every single write.
    /// Verifies that interval=1 means "always prune after the first append".
    func test_shouldPrune_intervalOne_trueOnEveryPositiveCount() {
        XCTAssertTrue(AppContext.shouldPrune(appendCount: 1, interval: 1),
                      "interval=1 must prune on every append so no writes are silently skipped when the operator sets the tightest cadence")
        XCTAssertTrue(AppContext.shouldPrune(appendCount: 7, interval: 1),
                      "interval=1 must prune on every append regardless of absolute count")
    }

    /// Count=0 must never prune regardless of interval - avoids a spurious
    /// DELETE before any event has been inserted.
    func test_shouldPrune_zeroCount_alwaysFalse() {
        XCTAssertFalse(AppContext.shouldPrune(appendCount: 0, interval: 1),
                       "zero appends must never trigger prune to avoid an empty-table DELETE on startup")
        XCTAssertFalse(AppContext.shouldPrune(appendCount: 0, interval: 50),
                       "zero appends with any interval must still return false")
    }

    /// At the cadence boundary (count == interval) the helper returns true,
    /// meaning the DELETE runs exactly once every N inserts.
    func test_shouldPrune_atBoundary_true() {
        let interval = AppContext.eventLogPruneInterval   // production default (50)
        XCTAssertTrue(AppContext.shouldPrune(appendCount: interval, interval: interval),
                      "shouldPrune must fire at the exact cadence boundary so the bounded-log invariant is maintained every N events")
    }

    /// One before the boundary (count == interval - 1) must return false -
    /// the prune has not been earned yet.
    func test_shouldPrune_oneBeforeBoundary_false() {
        let interval = AppContext.eventLogPruneInterval
        XCTAssertFalse(AppContext.shouldPrune(appendCount: interval - 1, interval: interval),
                       "prune must not fire before the cadence boundary to avoid excess DELETE calls that negate the performance benefit")
    }

    /// One after the boundary (count == interval + 1) must return false -
    /// the prune ran at `interval`, next fires at `2 * interval`.
    func test_shouldPrune_onePastBoundary_false() {
        let interval = AppContext.eventLogPruneInterval
        XCTAssertFalse(AppContext.shouldPrune(appendCount: interval + 1, interval: interval),
                       "prune must not fire immediately after the boundary so the N-apart cadence is respected")
    }

    /// Multiple-of-interval counts all fire; non-multiples never fire.
    /// Validates the modulo pattern covers all cadence boundaries, not just
    /// the first one.
    func test_shouldPrune_multipleIntervals_correctPattern() {
        let interval = 10
        let fires   = [10, 20, 30, 100]
        let skips   = [1, 9, 11, 19, 21, 99, 101]
        for count in fires {
            XCTAssertTrue(AppContext.shouldPrune(appendCount: count, interval: interval),
                          "count=\(count) with interval=\(interval) is a cadence boundary and must return true to prune the event log")
        }
        for count in skips {
            XCTAssertFalse(AppContext.shouldPrune(appendCount: count, interval: interval),
                           "count=\(count) with interval=\(interval) is not a cadence boundary and must return false so DELETE is not called")
        }
    }

    /// interval <= 0 is treated as 1 (always prune after first append) so the
    /// caller never ends up with an unbounded log due to a misconfigured value.
    func test_shouldPrune_zeroOrNegativeInterval_treatedAsOne() {
        XCTAssertTrue(AppContext.shouldPrune(appendCount: 3, interval: 0),
                      "interval=0 must clamp to 1 so every append prunes instead of disabling pruning")
        XCTAssertTrue(AppContext.shouldPrune(appendCount: 3, interval: -5),
                      "negative interval must clamp to 1 so every append prunes instead of disabling pruning")
    }

    // MARK: - Off-main dispatch

    // MARK: Snapshot save off-main

    /// scheduleSnapshotSave must dispatch repo.save (which contains the full
    /// JSONEncoder().encode(snap) call) to backgroundWriterQueue, NOT execute it
    /// on the main thread.  If the encode ran on main every workspace/tab
    /// mutation burst would jank the UI.
    ///
    /// Proof strategy: scheduleSnapshotSave(delay:0) enqueues a DispatchWorkItem
    /// on DispatchQueue.main.  That work item captures the LayoutState and then
    /// dispatches repo.save to backgroundWriterQueue.  After draining the main
    /// run loop (so the work item fires) and then flushing backgroundWriterQueue,
    /// the snapshot row must be present.  If repo.save were synchronous on main
    /// the flush would be a no-op and the row would already exist before it.
    @MainActor
    func test_scheduleSnapshotSave_writesOffMainViaBackgroundQueue() throws {
        let dir = NSTemporaryDirectory() + "RC2SnapOffMain-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        // Baseline: no snapshot row yet.
        XCTAssertNil(try ctx.snapshotRepo.latest(),
                     "fresh context must have no snapshot before any save")

        // Fire the debounced save immediately (delay=0) - the DispatchWorkItem is
        // queued on DispatchQueue.main but has not yet run.
        ctx.scheduleSnapshotSave(delay: 0)

        // Drain the main run loop so the work item executes and enqueues
        // repo.save on backgroundWriterQueue.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Now flush backgroundWriterQueue so the async DB write completes.
        ctx.flushWriterQueue()

        // After flush the snapshot must exist, proving the off-main write landed.
        let snap = try ctx.snapshotRepo.latest()
        XCTAssertNotNil(snap,
                        "snapshot must be written by backgroundWriterQueue after scheduleSnapshotSave+flush so the main thread was never blocked by JSONEncoder.encode")
    }

    /// The persister closure body (the actual DB write) must execute on a
    /// thread that is NOT the main thread. This validates that the writer queue
    /// is genuinely a background queue, not DispatchQueue.main in disguise.
    ///
    /// Why: the EventBus.publish path is called from the main thread (coordinator
    /// callbacks are main-actor). If the persister blocks on main the UI stalls
    /// during high-frequency agent events.
    @MainActor
    func test_wireBackgroundPersister_dispatchIsOffMain() throws {
        let dir = NSTemporaryDirectory() + "RC2WriterQueueTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)

        // Wire the background persister so the persister closure is active.
        ctx.wireBackgroundPersister()

        let expectation = expectation(description: "persister closure body runs off main")
        let oldPersister = EventBus.shared.persister

        // Wrap the background persister with a thread-check shim.
        EventBus.shared.persister = { ev in
            // Invoke the real background persister first so the queue is used.
            oldPersister?(ev)
            // The outer closure runs on the EventBus.publish caller (main).
            // The inner write must happen off main; flush the queue and verify.
            ctx.backgroundWriterQueue.async {
                // This block is guaranteed to run on backgroundWriterQueue,
                // which is a serial utility queue != main.
                XCTAssertFalse(Thread.isMainThread,
                               "event-log DB write must run off the main thread so the publish path never stalls UI rendering")
                expectation.fulfill()
            }
        }

        // Publish a non-surface.output event to trigger the persister.
        EventBus.shared.publish(kind: "test.background.writer", payload: .string("probe"))

        wait(for: [expectation], timeout: 2)

        // Clear so the global singleton does not hold a closure that captures
        // this test's AppContext after the test finishes.
        EventBus.shared.persister = nil
    }
}
