import XCTest
@testable import SocketServer

/// T015 -- EventBus ordering: backlog-vs-live interleave on subscribe, and
/// reloadFromPersistence dedupe/sort.
///
/// Why this matters: iOS opens a WebSocket and immediately calls events.recent
/// to replay the backlog. If a live event arrives between the snapshot read and
/// the subscribe call, both the backlog replay and the live feed must deliver
/// it exactly once and in sequence order. A regression here causes double-apply
/// or missing events on the iOS mirror.
final class EventBusOrderingTests: XCTestCase {

    func test_reentrantPublishThenUnsubscribeAndConcurrentSubscribeRemainFIFO() throws {
        let bus = EventBus()
        let outerDeliveryStarted = expectation(description: "outer event entered subscriber delivery")
        let outerPublishReturned = expectation(description: "outer publish returned without deadlock")
        let concurrentSubscriptionAttempted = expectation(description: "concurrent subscription attempted during delivery")
        let concurrentSubscriptionInstalled = expectation(description: "concurrent subscription installed")
        let releaseOuterDelivery = DispatchSemaphore(value: 0)
        let originalReceived = LockedEventSequences()
        let concurrentReceived = LockedEventSequences()
        let concurrentCursor = LockedEventSequences()

        var originalSubscriptionID: UUID!
        originalSubscriptionID = bus.subscribe(since: nil) { event in
            originalReceived.append(event.seq)
            guard event.kind == "outer" else { return }

            outerDeliveryStarted.fulfill()
            releaseOuterDelivery.wait()

            // WHY: a handler may derive a follow-up event and then retire itself.
            // The follow-up must be queued after the current delivery, so this
            // subscriber cannot receive the event it just produced.
            bus.publishRawForTesting(kind: "inner", payload: .null)
            bus.unsubscribe(originalSubscriptionID)
        }

        DispatchQueue.global().async {
            bus.publishRawForTesting(kind: "outer", payload: .null)
            outerPublishReturned.fulfill()
        }
        wait(for: [outerDeliveryStarted], timeout: 1)

        DispatchQueue.global().async {
            concurrentSubscriptionAttempted.fulfill()
            let subscription = bus.subscribeFromCurrent { event in
                concurrentReceived.append(event.seq)
            }
            concurrentCursor.append(subscription.cursor)
            concurrentSubscriptionInstalled.fulfill()
        }

        wait(for: [concurrentSubscriptionAttempted], timeout: 1)
        releaseOuterDelivery.signal()
        wait(for: [outerPublishReturned, concurrentSubscriptionInstalled], timeout: 2)

        // A synchronous publish from outside the delivery queue drains any
        // already-queued inner event before this final event returns.
        bus.publishRawForTesting(kind: "final", payload: .null)

        let cursor = try XCTUnwrap(concurrentCursor.values.first)
        XCTAssertTrue(cursor == 1 || cursor == 2,
                      "the racing subscription must linearize either before or after the queued inner event")
        let expectedConcurrentEvents: [Int64] = cursor == 1 ? [2, 3] : cursor == 2 ? [3] : []
        XCTAssertEqual(originalReceived.values, [1],
                       "publish-then-unsubscribe during delivery must not recursively redeliver the derived event to the retiring subscriber")
        XCTAssertEqual(concurrentReceived.values, expectedConcurrentEvents,
                       "the atomic cursor defines the exact no-gap, no-duplicate FIFO stream after concurrent subscription mutation")
        XCTAssertEqual(bus.subscriberCountForTests, 1,
                       "the retiring subscriber must be removed before queued delivery resumes")
        XCTAssertEqual(bus.snapshot().recent.map(\.seq), [1, 2, 3],
                       "reentrant publication must allocate one sequence exactly once and preserve global FIFO order")
    }

    func test_concurrentPublishersDeliverInAssignedSequenceOrder() {
        let bus = EventBus()
        let firstReachedPersistence = expectation(description: "seq 1 reached persistence")
        let delivered = expectation(description: "both events delivered")
        delivered.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let received = LockedEventSequences()

        bus.persister = { event in
            guard event.seq == 1 else { return }
            firstReachedPersistence.fulfill()
            releaseFirst.wait()
        }
        _ = bus.subscribe(since: nil) { event in
            received.append(event.seq)
            delivered.fulfill()
        }

        DispatchQueue.global().async {
            bus.publishRawForTesting(kind: "first", payload: .null)
        }
        wait(for: [firstReachedPersistence], timeout: 1)
        DispatchQueue.global().async {
            bus.publishRawForTesting(kind: "second", payload: .null)
        }
        Thread.sleep(forTimeInterval: 0.05)
        releaseFirst.signal()
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(
            received.values,
            [1, 2],
            "Assigned sequence is the reducer contract; concurrent publishers must not deliver seq 2 before seq 1."
        )
    }

    func test_subscribeFromCurrentAtomicallyCapturesCursorAndReceivesOnlyFutureEvents() {
        let bus = EventBus(recentLimit: 1)
        bus.publishRawForTesting(kind: "old.a", payload: .null)
        bus.publishRawForTesting(kind: "old.b", payload: .null)
        var received: [EventBus.Event] = []

        let subscription = bus.subscribeFromCurrent { received.append($0) }
        bus.publishRawForTesting(kind: "live.c", payload: .null)
        bus.publishRawForTesting(kind: "live.d", payload: .null)

        XCTAssertEqual(subscription.cursor, 2)
        XCTAssertEqual(received.map(\.seq), [3, 4])
        XCTAssertEqual(received.map(\.kind), ["live.c", "live.d"])
    }

    // MARK: - Backlog-vs-live interleave

    /// Scenario: client subscribes after several events have already been
    /// published. It passes since=seq2 to request only events after seq 2.
    /// One live event arrives concurrently before the backlog is drained.
    /// The subscriber must receive the correct backlog window plus live events
    /// in strict seq order -- no duplicates, no gaps.
    func test_subscribe_backlogliveInterleave_noDuplicatesNoGaps() {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "ev.a", payload: .number(1)) // seq 1
        bus.publishRawForTesting(kind: "ev.b", payload: .number(2)) // seq 2
        bus.publishRawForTesting(kind: "ev.c", payload: .number(3)) // seq 3

        var received: [Int64] = []
        // subscribe with since=2 -- should replay seq 3, then receive seq 4
        _ = bus.subscribe(since: 2) { received.append($0.seq) }

        // live event after subscribe
        bus.publishRawForTesting(kind: "ev.d", payload: .number(4)) // seq 4

        XCTAssertEqual(received, [3, 4],
                       "subscribe(since:2) must replay exactly seq>2 from backlog then deliver live events in order -- duplicating seq 3 or dropping seq 4 breaks iOS state reconstruction")
    }

    /// Scenario: two concurrent subscribers with different since values both
    /// receive their own correct backlog windows without cross-contamination.
    func test_subscribe_twoSubscribersWithDifferentSince_independentBacklogs() {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "ev.a", payload: .null) // seq 1
        bus.publishRawForTesting(kind: "ev.b", payload: .null) // seq 2
        bus.publishRawForTesting(kind: "ev.c", payload: .null) // seq 3

        var receivedA: [Int64] = []
        var receivedB: [Int64] = []

        _ = bus.subscribe(since: 0) { receivedA.append($0.seq) }   // wants all backlog
        _ = bus.subscribe(since: 2) { receivedB.append($0.seq) }   // wants only seq 3+

        XCTAssertEqual(receivedA, [1, 2, 3],
                       "subscriber with since=0 must receive the full backlog -- gaps mean iOS misses earlier state changes")
        XCTAssertEqual(receivedB, [3],
                       "subscriber with since=2 must receive only seq 3 -- replaying earlier events causes iOS to double-apply mutations")
    }

    /// Scenario: a live event is published during the backlog delivery window.
    /// The subscriber receives the live event AFTER all backlog events, never
    /// interleaved in the middle. (EventBus.subscribe drains backlog
    /// synchronously before any live delivery -- verify the ordering contract.)
    func test_subscribe_liveEventsDontInterleaveWithBacklog() {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "base.a", payload: .null) // seq 1
        bus.publishRawForTesting(kind: "base.b", payload: .null) // seq 2

        var order: [String] = []
        _ = bus.subscribe(since: 0) { order.append($0.kind) }

        // live events after subscribe
        bus.publishRawForTesting(kind: "live.c", payload: .null) // seq 3
        bus.publishRawForTesting(kind: "live.d", payload: .null) // seq 4

        XCTAssertEqual(order, ["base.a", "base.b", "live.c", "live.d"],
                       "backlog events must arrive before live events so iOS reducer applies history before present -- out-of-order delivery corrupts UI state")
    }

    // MARK: - reloadFromPersistence dedupe / sort

    /// Scenario: bus has live events in memory (seq 1, 2). Persistence
    /// provides overlapping events (seq 1, 2, 3) where seq 1 and 2 are
    /// duplicates. After reload, the backlog must contain exactly [1,2,3]
    /// with no duplicates and sorted by seq.
    func test_reloadFromPersistence_deduplicatesOverlappingEvents() {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "mem.a", payload: .null)  // seq 1
        bus.publishRawForTesting(kind: "mem.b", payload: .null)  // seq 2

        let (snapSeq, _) = bus.snapshot()
        XCTAssertEqual(snapSeq, 2)

        // Simulate persisted window: includes the same seq 1+2 already in
        // memory plus a new seq 3 that arrived before the in-process bus was
        // warm (e.g., previous app session events re-loaded from DB).
        let persisted: [EventBus.Event] = [
            EventBus.Event(seq: 1, kind: "persisted.a", payload: .null, ts: 1000),
            EventBus.Event(seq: 2, kind: "persisted.b", payload: .null, ts: 1001),
            EventBus.Event(seq: 3, kind: "persisted.c", payload: .null, ts: 1002)
        ]

        bus.reloadFromPersistence(lastSeq: 3, recent: persisted)

        var replayed: [Int64] = []
        _ = bus.subscribe(since: 0) { replayed.append($0.seq) }

        // seq 1 and 2 must appear exactly once (not twice)
        XCTAssertEqual(replayed.filter { $0 == 1 }.count, 1,
                       "seq 1 must appear exactly once after reload -- duplicating it makes iOS apply the same state change twice")
        XCTAssertEqual(replayed.filter { $0 == 2 }.count, 1,
                       "seq 2 must appear exactly once after reload")
        XCTAssertTrue(replayed.contains(3),
                      "seq 3 from persistence must be present so iOS gets events from the previous session")
    }

    /// Scenario: persistence provides events in unsorted order. After reload
    /// the backlog must be sorted by seq so a subscribing client receives a
    /// monotonically increasing event stream.
    func test_reloadFromPersistence_sortsEventsBySeq() {
        let bus = EventBus()

        let persisted: [EventBus.Event] = [
            EventBus.Event(seq: 3, kind: "ev.c", payload: .null, ts: 1002),
            EventBus.Event(seq: 1, kind: "ev.a", payload: .null, ts: 1000),
            EventBus.Event(seq: 2, kind: "ev.b", payload: .null, ts: 1001)
        ]

        bus.reloadFromPersistence(lastSeq: 3, recent: persisted)

        var replayed: [Int64] = []
        _ = bus.subscribe(since: 0) { replayed.append($0.seq) }

        XCTAssertEqual(replayed, [1, 2, 3],
                       "events from persistence must be sorted by seq before delivery -- out-of-order events cause iOS reducer to apply mutations in wrong order")
    }

    /// Scenario: reloadFromPersistence must advance lastSeq to at least the
    /// max persisted seq, so new live events continue the sequence without
    /// collision.
    func test_reloadFromPersistence_advancesLastSeq() {
        let bus = EventBus()
        // bus has no events yet (lastSeq = 0)

        let persisted: [EventBus.Event] = [
            EventBus.Event(seq: 10, kind: "old.event", payload: .null, ts: 999)
        ]
        bus.reloadFromPersistence(lastSeq: 10, recent: persisted)

        // publish a new live event -- it must get seq 11, not seq 1
        bus.publishRawForTesting(kind: "new.event", payload: .null)

        var seqs: [Int64] = []
        _ = bus.subscribe(since: 0) { seqs.append($0.seq) }

        XCTAssertTrue(seqs.contains(10), "persisted event seq 10 must be in backlog")
        XCTAssertTrue(seqs.contains(11),
                      "live event after reload must get seq 11, not seq 1 -- a collision resets the iOS mirror's catchup pointer and drops events")
        // must not gap: no seq between 10 and 11 is missing, and no seq > 11
        XCTAssertFalse(seqs.contains(where: { $0 < 10 }),
                       "no event should exist below the persisted lastSeq")
    }

    // MARK: - shouldRetainRecentEvent interplay with reloadFromPersistence

    /// Scenario: some event kinds (e.g. surface.output) are excluded from the
    /// backlog via shouldRetainRecentEvent. reloadFromPersistence must respect
    /// this filter so high-volume events from a previous session do not fill
    /// the in-memory replay window.
    func test_reloadFromPersistence_honoursShouldRetainFilter() {
        let bus = EventBus()
        bus.shouldRetainRecentEvent = { $0.kind != "surface.output" }

        let persisted: [EventBus.Event] = [
            EventBus.Event(seq: 1, kind: "workspace.created", payload: .null, ts: 1000),
            EventBus.Event(seq: 2, kind: "surface.output", payload: .null, ts: 1001),
            EventBus.Event(seq: 3, kind: "surface.created", payload: .null, ts: 1002)
        ]
        bus.reloadFromPersistence(lastSeq: 3, recent: persisted)

        var kinds: [String] = []
        _ = bus.subscribe(since: 0) { kinds.append($0.kind) }

        XCTAssertFalse(kinds.contains("surface.output"),
                       "surface.output must not be added to the replay backlog during reload -- it would pin megabytes of terminal data in memory across sessions")
        XCTAssertTrue(kinds.contains("workspace.created"))
        XCTAssertTrue(kinds.contains("surface.created"))
    }

    // MARK: - reloadFromPersistence: precomputed encoding correctness

    /// Verifies that the off-lock precompute path (moved out of the critical
    /// section for contention reduction) produces the same backlog as the
    /// former in-lock path: correct event count, correct byte accounting, and
    /// correct recentEvents trimming behaviour.
    ///
    /// Why: encoding was moved before lock acquisition; if the precomputed
    /// encoded size is wrong, recentEvents will report incorrect truncation
    /// decisions and iOS will request unnecessary baselines.
    func test_reloadFromPersistence_precomputedByteCountMatchesActualEncodedSize() {
        // tight byte limit so trimRecent fires and exercises the byte-count path
        let bus = EventBus(recentLimit: 512, recentByteLimit: 4096)

        let persisted: [EventBus.Event] = [
            EventBus.Event(seq: 1, kind: "workspace.created", payload: .string(String(repeating: "a", count: 200)), ts: 1000),
            EventBus.Event(seq: 2, kind: "surface.created",   payload: .string(String(repeating: "b", count: 200)), ts: 1001),
            EventBus.Event(seq: 3, kind: "agent.started",     payload: .string(String(repeating: "c", count: 200)), ts: 1002)
        ]
        bus.reloadFromPersistence(lastSeq: 3, recent: persisted)

        // recentEvents uses the same encodedSize path; if byte counts were
        // mis-tracked the truncated flag and event list would disagree with reality
        let result = bus.recentEvents(since: 0, maxBytes: 4096)
        // all three events fit within 4 KB; none should be truncated
        XCTAssertFalse(result.truncated,
                       "recentEvents must not report truncation when all events fit -- a wrong byte count from the precompute path causes iOS to request a full baseline on every reconnect")
        XCTAssertEqual(result.events.map(\.seq).sorted(), [1, 2, 3],
                       "all three persisted events must be present after reload -- a precompute encoding mismatch would silently drop events via over-aggressive trimRecent")
    }
}

private final class LockedEventSequences: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
