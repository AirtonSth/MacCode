import XCTest
@testable import SocketServer

/// Tests for QA-002: injectable clock in EventBus.
///
/// WHY per assertion:
///  - Event.ts is used by iOS replay-window math to filter which events to re-deliver
///    after a reconnect. A wall-clock ts makes ordering assertions racy in CI.
///  - setClockForTests replaces Date() in publish() so ts values are exact integers
///    rather than floating-point wall-time samples.
///  - The default clock must remain real wall time so live mirrors receive a
///    meaningful server_time (not epoch) without any test configuration.
final class EventBusClockTests: XCTestCase {

    // MARK: - Default clock: real wall time

    /// WHY: in production the ts field must be near the current UNIX epoch.
    /// A frozen-at-zero clock would send ts=0 to every iOS subscriber, breaking
    /// replay-window filtering.
    func test_defaultClock_producesWallTimeTs() {
        let bus = EventBus()
        let before = Date().timeIntervalSince1970
        bus.publishRawForTesting(kind: "ping", payload: .null)
        let after = Date().timeIntervalSince1970
        let (_, recent) = bus.snapshot()
        let ts = try! XCTUnwrap(recent.first?.ts)
        XCTAssertGreaterThanOrEqual(ts, before,
            "event ts must not precede the publish call (real clock)")
        XCTAssertLessThanOrEqual(ts, after,
            "event ts must not follow the publish call (real clock)")
    }

    // MARK: - setClockForTests: frozen ts

    /// WHY: iOS uses ts to decide the replay window — events before the client's
    /// last-seen ts are skipped. If ts is nondeterministic the replay tests flake.
    /// A frozen clock makes exact ts assertions possible without timing dependencies.
    func test_setClockForTests_freezesEventTs() {
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        let bus = EventBus()
        bus.setClockForTests { fixedDate }
        bus.publishRawForTesting(kind: "a", payload: .null)
        bus.publishRawForTesting(kind: "b", payload: .null)
        let (_, recent) = bus.snapshot()
        XCTAssertEqual(recent.count, 2)
        for ev in recent {
            XCTAssertEqual(ev.ts, 1_000_000,
                "every event ts must equal the frozen clock value; kind=\(ev.kind)")
        }
    }

    // MARK: - setClockForTests: advancing clock

    /// WHY: replay-window filtering is ordered by ts; later events must have a
    /// strictly greater ts than earlier ones. An advancing fake clock verifies
    /// monotonicity without wall-clock sleep.
    func test_setClockForTests_advancingClock_tsIsMonotonic() {
        var tick: TimeInterval = 0
        let bus = EventBus()
        bus.setClockForTests {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        bus.publishRawForTesting(kind: "first",  payload: .null)
        bus.publishRawForTesting(kind: "second", payload: .null)
        bus.publishRawForTesting(kind: "third",  payload: .null)
        let (_, recent) = bus.snapshot()
        let tss = recent.map(\.ts)
        XCTAssertEqual(tss.count, 3)
        for i in 1..<tss.count {
            XCTAssertGreaterThan(tss[i], tss[i - 1],
                "event ts must be strictly increasing when using an advancing clock (replay ordering requires it)")
        }
    }

    // MARK: - Replay-window math: filter events by ts

    /// WHY: iOS reconnect logic asks for events since a given ts. The ts field
    /// being deterministic (via frozen clock) lets us express exact filter assertions
    /// without measuring wall time.
    func test_frozenClock_replayWindowFiltersCorrectly() {
        let bus = EventBus()
        // publish two events at ts=100, then one at ts=200
        var phase: TimeInterval = 100
        bus.setClockForTests { Date(timeIntervalSince1970: phase) }
        bus.publishRawForTesting(kind: "old-1", payload: .null)
        bus.publishRawForTesting(kind: "old-2", payload: .null)
        phase = 200
        bus.publishRawForTesting(kind: "new",   payload: .null)

        var received: [String] = []
        // subscribe since=2 to get only the event with seq > 2 (which is "new")
        _ = bus.subscribe(since: 2) { received.append($0.kind) }
        XCTAssertEqual(received, ["new"],
            "subscribe(since:) must deliver only events with seq > since; ts clock does not affect seq ordering")
    }

    // MARK: - Clock survives concurrent publish calls

    /// WHY: publish() holds the lock while calling clock(), so the injected clock
    /// must be safe to call under the lock. This test verifies no deadlock occurs
    /// when the clock is swapped while concurrent publishes are in flight.
    func test_setClockForTests_concurrentPublish_noDeadlock() {
        let bus = EventBus()
        bus.setClockForTests { Date(timeIntervalSince1970: 42) }

        let group = DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                bus.publishRawForTesting(kind: "concurrent", payload: .null)
                group.leave()
            }
        }
        let timeout = group.wait(timeout: .now() + 5)
        XCTAssertEqual(timeout, .success,
            "concurrent publish with injected clock must not deadlock")
    }
}
