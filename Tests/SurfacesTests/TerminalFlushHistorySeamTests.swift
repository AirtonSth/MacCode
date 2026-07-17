import XCTest
@testable import Surfaces

/// Tests for the history-flush wait-decision seam (PERF: TerminalSurface.swift).
///
/// WHY these tests exist:
///
/// Problem 1 — UI stall on tab close:
///   `close()` previously called `flushHistory(wait: true)`, which runs
///   `historyQueue.sync` on the main thread. A slow disk (or a large pending
///   buffer) blocks the entire UI until the write finishes. On a spinning-disk
///   or an NFS mount this can stall for hundreds of milliseconds per tab close.
///
/// Problem 2 — Silent history loss on app quit:
///   App-quit flushes via `flushPersistedHistory()` (called from
///   `applicationWillTerminate`). If that path were made async, the app could
///   exit before the queued write item runs, dropping the unflushed tail.
///
/// Fix: `flushShouldWait(reason:)` is the single decision point. `tabClose`
/// returns false (async) and `appTermination` returns true (sync barrier).
///
/// Data-loss prevention on async tab-close:
///   Inside `flushHistory(wait:)`, the pending buffer is moved (not copied)
///   into the DispatchWorkItem closure via Swift COW reassignment before the
///   work item is enqueued. The `historyQueue` retains the work item until it
///   completes. Even if the TerminalSurface is torn down immediately after
///   `close()`, the captured `data: Data` value outlives the surface — no
///   bytes are dropped.
final class TerminalFlushHistorySeamTests: XCTestCase {

    // MARK: - flushShouldWait seam

    func test_tabClose_doesNotWait() {
        // WHY: tab close runs on the main thread; a synchronous historyQueue.sync
        // stalls the UI for every millisecond the disk write takes. Async flush
        // is mandatory so AppKit can process the next event immediately.
        XCTAssertFalse(
            TerminalSurface.flushShouldWait(reason: .tabClose),
            "tab-close flush must be async (wait=false) so a slow disk never blocks the main thread during tab teardown"
        )
    }

    func test_appTermination_is_async_and_joins_global_barrier() {
        // WHY: per-surface history disposition is always async. App quit durability
        // comes from collecting SurfaceTerminationBarrier values and waiting on
        // one shared deadline in closeSurfacesForApplicationTermination — not from
        // a per-surface historyQueue.sync on the main actor.
        XCTAssertFalse(
            TerminalSurface.flushShouldWait(reason: .appTermination),
            "app-termination must not perform a per-surface synchronous SQLite wait on the main actor"
        )
    }

    func test_tabClose_and_appTermination_share_async_disposition() {
        // WHY: both close reasons enqueue history work and return a joinable
        // barrier. Diverging wait semantics here would reintroduce main-thread
        // stalls on tab close or drop the shared quit barrier contract.
        XCTAssertEqual(
            TerminalSurface.flushShouldWait(reason: .tabClose),
            TerminalSurface.flushShouldWait(reason: .appTermination),
            "tabClose and appTermination both use async disposition joined by barriers"
        )
    }

    func test_flushShouldWait_isPure_for_tabClose() {
        // WHY: the seam must be side-effect-free so callers and tests can query
        // it without state mutation. Calling it twice must yield the same result.
        let first  = TerminalSurface.flushShouldWait(reason: .tabClose)
        let second = TerminalSurface.flushShouldWait(reason: .tabClose)
        XCTAssertEqual(first, second,
                       "flushShouldWait must be pure/idempotent — repeated calls for the same reason must return the same value")
    }

    func test_flushShouldWait_isPure_for_appTermination() {
        // WHY: same purity requirement for the termination path; a stateful
        // implementation would break the app-quit barrier on second call.
        let first  = TerminalSurface.flushShouldWait(reason: .appTermination)
        let second = TerminalSurface.flushShouldWait(reason: .appTermination)
        XCTAssertEqual(first, second,
                       "flushShouldWait must be pure/idempotent for appTermination — barrier correctness depends on it")
    }
}
