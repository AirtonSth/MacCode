import XCTest
@testable import SocketServer

/// QA item :81 — EventBus subscription leak guard.
///
/// WHY: every surface open/close cycle calls subscribe()+unsubscribe(). If
/// unsubscribe() fails to remove the entry from `subscribers` (or the snapshot
/// cache), the count grows monotonically with each surface lifetime. On a
/// long-running session with many tab/pane open-close cycles that means hundreds
/// of dead closures accumulate, receiving every publish() call and wasting CPU
/// plus memory proportional to the number of stale subscribers (Perf #2).
///
/// The subscriber-count accessor (subscriberCountForTests) is the minimal test
/// seam: read-only, zero production impact, no changes to publish logic.
final class EventBusSubscriberLeakTests: XCTestCase {

    // MARK: - Baseline after single subscribe/unsubscribe

    /// Create one subscriber, unsubscribe, assert count returns to zero.
    func test_subscribeThenUnsubscribe_returnsToZero() {
        let bus = EventBus()
        let baseline = bus.subscriberCountForTests

        let id = bus.subscribe(since: nil) { _ in }
        XCTAssertEqual(bus.subscriberCountForTests, baseline + 1,
            "subscriber count must increase by 1 after subscribe()")

        bus.unsubscribe(id)
        XCTAssertEqual(bus.subscriberCountForTests, baseline,
            "subscriber count must return to baseline after unsubscribe(); " +
            "a retained entry means every future publish() delivers to a dead handler " +
            "— unbounded accumulation across surface open/close cycles == Perf #2")
    }

    // MARK: - Baseline after N subscribe/unsubscribe cycles

    /// Simulate N surface open/close cycles; subscriber count must remain at
    /// baseline after every cycle, not drift upward.
    func test_repeatedSubscribeUnsubscribe_noDrift() {
        let bus = EventBus()
        let baseline = bus.subscriberCountForTests

        for cycle in 1...50 {
            let id = bus.subscribe(since: nil) { _ in }
            bus.unsubscribe(id)
            XCTAssertEqual(bus.subscriberCountForTests, baseline,
                "subscriber count drifted above baseline after \(cycle) open/close cycle(s); " +
                "each unmatched entry will fire a dead handler on every publish() for the " +
                "lifetime of the process — memory and CPU leak proportional to surface churn")
        }
    }

    // MARK: - Mixed active + closed subscribers

    /// Keep some subscribers active while closing others; the count of active
    /// subscribers must equal exactly the number not yet unsubscribed.
    func test_partialUnsubscribe_countMatchesActiveOnly() {
        let bus = EventBus()
        let baseline = bus.subscriberCountForTests

        let id1 = bus.subscribe(since: nil) { _ in }
        let id2 = bus.subscribe(since: nil) { _ in }
        let id3 = bus.subscribe(since: nil) { _ in }

        XCTAssertEqual(bus.subscriberCountForTests, baseline + 3)

        bus.unsubscribe(id1)
        XCTAssertEqual(bus.subscriberCountForTests, baseline + 2,
            "after removing id1 exactly 2 active subscribers must remain; " +
            "a ghost entry for id1 would inflate CPU cost of every subsequent publish()")

        bus.unsubscribe(id2)
        XCTAssertEqual(bus.subscriberCountForTests, baseline + 1,
            "after removing id1 and id2 exactly 1 active subscriber must remain")

        bus.unsubscribe(id3)
        XCTAssertEqual(bus.subscriberCountForTests, baseline,
            "all subscribers removed; count must equal baseline")
    }

    // MARK: - Double-unsubscribe is idempotent

    /// Calling unsubscribe() twice with the same ID must not corrupt the count
    /// (negative count or panic would be worse than the leak it guards against).
    func test_doubleUnsubscribe_isIdempotent() {
        let bus = EventBus()
        let baseline = bus.subscriberCountForTests

        let id = bus.subscribe(since: nil) { _ in }
        bus.unsubscribe(id)
        bus.unsubscribe(id)   // second call must be a no-op

        XCTAssertEqual(bus.subscriberCountForTests, baseline,
            "double-unsubscribe must leave count at baseline; " +
            "a negative count or crash here is worse than the leak it was meant to fix")
    }

    // MARK: - subscribersSnapshot cache is consistent with subscribers dict

    /// After subscribe+unsubscribe, publish must not call any removed handler.
    /// WHY: subscribers dict and subscribersSnapshot cache must be kept in sync;
    /// if unsubscribe() removes from the dict but forgets to rebuild the snapshot,
    /// dead handlers still fire on every publish() (the exact Perf #2 defect).
    func test_unsubscribedHandlerNeverFires() {
        let bus = EventBus()
        var ghostCalled = false

        let id = bus.subscribe(since: nil) { _ in ghostCalled = true }
        bus.unsubscribe(id)

        bus.publish(kind: "ping", payload: .null)

        XCTAssertFalse(ghostCalled,
            "handler must not fire after unsubscribe(); " +
            "snapshot cache out-of-sync with subscribers dict == removed handlers " +
            "still receiving every event, wasting CPU on each publish() call")
    }
}
