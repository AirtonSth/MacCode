import XCTest
@testable import AppShell

@MainActor
final class TailcatNetworkPathObserverTests: XCTestCase {
    func testFirstPathUpdateIsABaseline() {
        // WHY: the monitor reports the current path as soon as it starts.
        // Launch already reconciles; it must not cost a second reconcile.
        let probe = PathObserverProbe()
        let observer = probe.makeObserver()

        observer.pathUpdated(usable: true)
        probe.fireAll()

        XCTAssertEqual(probe.actions.count, 0)
        XCTAssertEqual(probe.calls, 0)
    }

    func testBurstOfUsableUpdatesCallsOnce() {
        // WHY: an interface change arrives as several path updates. The Mac
        // owes one catalog GET per settled change, not one per event.
        let probe = PathObserverProbe()
        let observer = probe.makeObserver(settle: 7)

        observer.pathUpdated(usable: true)
        for _ in 0..<5 { observer.pathUpdated(usable: true) }
        XCTAssertEqual(probe.calls, 0, "nothing is called before the settle time passes")
        probe.fireAll()

        XCTAssertEqual(probe.delays, [7, 7, 7, 7, 7], "every wait is the settle interval")
        XCTAssertEqual(probe.cancels, 4)
        XCTAssertEqual(probe.calls, 1)
    }

    func testLossBeforeSettleCancelsEvenWhenTheCancelIsLost() {
        // WHY: the default scheduler hops from a work item to a Task, and a
        // cancel between the two is lost. The stale action must be harmless:
        // no reconcile for a path that is gone.
        let probe = PathObserverProbe()
        let observer = probe.makeObserver()

        observer.pathUpdated(usable: true)
        observer.pathUpdated(usable: true)
        observer.pathUpdated(usable: false)
        XCTAssertEqual(probe.cancels, 1)
        probe.fireAll()

        XCTAssertEqual(probe.actions.count, 1)
        XCTAssertEqual(probe.calls, 0)
    }

    func testFlappingThatNeverSettlesNeverCalls() {
        // WHY: on a network that drops again before it settles, the 15 s poll
        // stays the only reconciler. Each replaced action still fires here,
        // as a lost cancel would let it.
        let probe = PathObserverProbe()
        let observer = probe.makeObserver()

        observer.pathUpdated(usable: true)
        for round in 0..<5 {
            observer.pathUpdated(usable: false)
            if round > 0 { probe.fire(round - 1) }
            observer.pathUpdated(usable: true)
        }

        XCTAssertEqual(probe.actions.count, 5)
        XCTAssertEqual(probe.calls, 0)
    }

    func testRegainAfterLossCallsOnce() {
        // WHY: the Mac wakes before its network is up, so the wake's own
        // reconcile fails. The regain is what must start the next one.
        let probe = PathObserverProbe()
        let observer = probe.makeObserver()

        observer.pathUpdated(usable: true)
        observer.pathUpdated(usable: false)
        XCTAssertEqual(probe.actions.count, 0, "a loss schedules nothing")
        observer.pathUpdated(usable: true)
        probe.fireAll()

        XCTAssertEqual(probe.actions.count, 1)
        XCTAssertEqual(probe.calls, 1)
    }

    func testStopCancelsThePendingCall() {
        // WHY: nothing may run after app teardown. The baseline step is
        // needed: without it nothing is scheduled and the test proves nothing.
        let probe = PathObserverProbe()
        let observer = probe.makeObserver()

        observer.pathUpdated(usable: true)
        observer.pathUpdated(usable: true)
        XCTAssertEqual(probe.actions.count, 1)
        observer.stop()
        probe.fireAll()

        XCTAssertEqual(probe.cancels, 1)
        XCTAssertEqual(probe.calls, 0)
    }
}

/// Captures every scheduled action instead of waiting. Its cancellation only
/// counts: a test can still fire a cancelled action, which is the lost cancel.
@MainActor
private final class PathObserverProbe {
    private(set) var actions: [@MainActor () -> Void] = []
    private(set) var delays: [TimeInterval] = []
    private(set) var cancels = 0
    private(set) var calls = 0

    func makeObserver(
        settle: TimeInterval = TailcatNetworkPathObserver.settleInterval
    ) -> TailcatNetworkPathObserver {
        TailcatNetworkPathObserver(
            settle: settle,
            schedule: { delay, action in
                self.delays.append(delay)
                self.actions.append(action)
                return { self.cancels += 1 }
            },
            onUsable: { self.calls += 1 }
        )
    }

    func fire(_ index: Int) {
        actions[index]()
    }

    func fireAll() {
        for action in actions { action() }
    }
}
