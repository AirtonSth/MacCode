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

    // MARK: - Backlog-vs-live interleave

    /// Scenario: client subscribes after several events have already been
    /// published. It passes since=seq2 to request only events after seq 2.
    /// One live event arrives concurrently before the backlog is drained.
    /// The subscriber must receive the correct backlog window plus live events
    /// in strict seq order -- no duplicates, no gaps.
    func test_subscribe_backlogliveInterleave_noDuplicatesNoGaps() {
        let bus = EventBus()
        bus.publish(kind: "ev.a", payload: .number(1)) // seq 1
        bus.publish(kind: "ev.b", payload: .number(2)) // seq 2
        bus.publish(kind: "ev.c", payload: .number(3)) // seq 3

        var received: [Int64] = []
        // subscribe with since=2 -- should replay seq 3, then receive seq 4
        _ = bus.subscribe(since: 2) { received.append($0.seq) }

        // live event after subscribe
        bus.publish(kind: "ev.d", payload: .number(4)) // seq 4

        XCTAssertEqual(received, [3, 4],
                       "subscribe(since:2) must replay exactly seq>2 from backlog then deliver live events in order -- duplicating seq 3 or dropping seq 4 breaks iOS state reconstruction")
    }

    /// Scenario: two concurrent subscribers with different since values both
    /// receive their own correct backlog windows without cross-contamination.
    func test_subscribe_twoSubscribersWithDifferentSince_independentBacklogs() {
        let bus = EventBus()
        bus.publish(kind: "ev.a", payload: .null) // seq 1
        bus.publish(kind: "ev.b", payload: .null) // seq 2
        bus.publish(kind: "ev.c", payload: .null) // seq 3

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
        bus.publish(kind: "base.a", payload: .null) // seq 1
        bus.publish(kind: "base.b", payload: .null) // seq 2

        var order: [String] = []
        _ = bus.subscribe(since: 0) { order.append($0.kind) }

        // live events after subscribe
        bus.publish(kind: "live.c", payload: .null) // seq 3
        bus.publish(kind: "live.d", payload: .null) // seq 4

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
        bus.publish(kind: "mem.a", payload: .null)  // seq 1
        bus.publish(kind: "mem.b", payload: .null)  // seq 2

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
        bus.publish(kind: "new.event", payload: .null)

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
}
