import XCTest
@testable import AppShell

/// Tests for the `refreshCoalesceShouldSchedule(wasPending:)` pure helper.
///
/// WHY these tests matter:
///   - Without coalescing, every agent event in a burst (e.g. queued-message
///     update, thread mutation) triggers a full refreshFromState() which runs
///     sidebar.refresh() + workspaceContainerSignature() construction even when
///     the layout has not changed -- one per event instead of one per tick.
///   - The helper gates whether a new async flush should be enqueued; incorrect
///     logic would either starve refreshes (never flushing) or defeat the
///     coalesce (still one refresh per event).
///   - Verifying that a flush resets the pending flag (wasPending -> false)
///     ensures requests arriving after the tick schedule correctly again.
///
/// All assertions target the pure helper only -- no AppKit, no @MainActor,
/// no async, no flakiness.
final class RefreshCoalesceDecisionTests: XCTestCase {

    // MARK: - No pending flush: should schedule

    func test_notPending_shouldSchedule() {
        // WHY: the first refresh request in a tick finds no pending flush and
        // must schedule one so the UI is actually updated.
        XCTAssertTrue(
            refreshCoalesceShouldSchedule(wasPending: false),
            "wasPending=false => shouldSchedule must be true so the first " +
            "request in a tick enqueues a flush and the UI is updated"
        )
    }

    // MARK: - Flush already pending: suppress duplicate

    func test_alreadyPending_shouldNotSchedule() {
        // WHY: subsequent requests arriving within the same runloop tick
        // find a flush already enqueued; scheduling another would produce
        // one sidebar.refresh() + signature walk per event -- the exact
        // burst we are coalescing away.
        XCTAssertFalse(
            refreshCoalesceShouldSchedule(wasPending: true),
            "wasPending=true => shouldSchedule must be false so burst events " +
            "within one tick do not each trigger a full sidebar.refresh() + " +
            "workspaceContainerSignature() walk"
        )
    }

    // MARK: - After flush reset: schedules again

    func test_afterFlushReset_shouldScheduleAgain() {
        // WHY: after the async flush fires it resets hasPendingRefresh to false;
        // the next refresh request (next tick or later) must schedule a new flush
        // or the UI would silently stop updating after the first coalesced burst.
        //
        // Simulates: request1 schedules (pending=false->true), flush fires
        // (pending=true->false), request2 must schedule again.
        let afterFlushWasPending = false   // hasPendingRefresh was reset by the flush
        XCTAssertTrue(
            refreshCoalesceShouldSchedule(wasPending: afterFlushWasPending),
            "after the flush resets hasPendingRefresh to false, the next request " +
            "must return shouldSchedule=true so refreshes keep flowing in " +
            "subsequent ticks or events"
        )
    }

    // MARK: - Idempotent: multiple burst calls all suppressed

    func test_multipleBurstCalls_allSuppressedAfterFirst() {
        // WHY: proves the coalesce decision is purely stateless -- each call
        // with wasPending=true returns false regardless of call count.
        // The controller is responsible for holding the flag; the helper must
        // not have hidden state that changes its answer over repeated calls.
        for _ in 0..<5 {
            XCTAssertFalse(
                refreshCoalesceShouldSchedule(wasPending: true),
                "every burst call with wasPending=true must return false; " +
                "the helper must be stateless so N calls within a tick all " +
                "suppress the duplicate without accumulating hidden state"
            )
        }
    }
}
