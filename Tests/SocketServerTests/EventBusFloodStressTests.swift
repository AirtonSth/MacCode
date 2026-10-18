import XCTest
@testable import SocketServer

/// QA item :80 — EventBus flood stress: buffer-bound assertions.
///
/// WHY: an unbounded recent buffer is a memory DoS vector. A single fast publisher
/// can grow recent[] and recentBytes without limit if trimRecent() is not invoked
/// on every publish path.  These tests drive EventBus directly (in-process) with
/// >512 events / >1 MB of payload and assert:
///   (a) recent count never exceeds recentLimit (capacity DoS prevention)
///   (b) accumulated bytes never exceed recentByteLimit (byte DoS prevention)
///   (c) recentEvents() sets requiresBaseline when it cannot replay all events
///       inside the caller-supplied byte cap (iOS must re-fetch a snapshot)
///   (d) the oldest events are the ones dropped, preserving the most-recent state
///       (LRU eviction preserves freshness)
///
/// A "real socket" is NOT required — the buffer invariants are in-process state;
/// socket I/O tests live in integration lanes.
final class EventBusFloodStressTests: XCTestCase {

    // MARK: - Count cap

    /// Publish recentLimit*2+1 events and assert recent buffer never grows past cap.
    func test_flood_recentCountStaysAtOrBelowLimit() {
        // small limit so the flood terminates quickly
        let limit = 64
        let bus = EventBus(recentLimit: limit, recentByteLimit: 512 * 1024)

        for i in 0..<(limit * 2 + 1) {
            bus.publishRawForTesting(kind: "flood", payload: .number(Double(i)))
        }

        let count = bus.recentCountForTests
        XCTAssertLessThanOrEqual(count, limit,
            "recent buffer (\(count)) exceeds recentLimit (\(limit)); " +
            "unbounded growth == memory DoS when a fast sender never pauses")
    }

    // MARK: - Byte cap

    /// Publish events whose total encoded size exceeds recentByteLimit and assert
    /// recentBytes stays at or below the cap.
    func test_flood_recentBytesStayAtOrBelowByteLimit() {
        let byteLimit = EventBus.defaultRecentByteLimit
        let bus = EventBus(recentLimit: 4096, recentByteLimit: byteLimit)

        // each payload ~4 KB; 800 events exceed the bounded production cap
        let chunk = String(repeating: "x", count: 4_000)
        for i in 0..<800 {
            bus.publishRawForTesting(kind: "flood.\(i)", payload: .string(chunk))
        }

        let bytes = bus.recentBytesForTests
        XCTAssertLessThanOrEqual(bytes, byteLimit,
            "recentBytes (\(bytes)) exceeds recentByteLimit (\(byteLimit)); " +
            "a multi-MB flood must not pin more than the production byte budget")
    }

    // MARK: - Both caps simultaneously (default limits, >512 events)

    /// Publish more events than the default recentLimit with small payloads
    /// and assert both count and byte invariants hold simultaneously.
    func test_flood_defaultLimits_countAndByteBothBounded() {
        // use default limits to verify production config is correctly wired
        let bus = EventBus()
        let limit = EventBus.defaultRecentLimit
        let byteLimit = EventBus.defaultRecentByteLimit

        for i in 0..<(limit + 100) {
            bus.publishRawForTesting(kind: "e\(i)", payload: .number(Double(i)))
        }

        let count = bus.recentCountForTests
        let bytes = bus.recentBytesForTests

        XCTAssertLessThanOrEqual(count, limit,
            "recent count (\(count)) exceeds default recentLimit=\(limit) after flood")
        XCTAssertLessThanOrEqual(bytes, byteLimit,
            "recentBytes (\(bytes)) exceeds default recentByteLimit after flood")
    }

    // MARK: - requiresBaseline flag

    /// After flooding the bus, recentEvents() with a tight maxBytes cap must set
    /// requiresBaseline so iOS knows it cannot replay from cache alone and must
    /// fetch a fresh snapshot instead of showing partial/stale state.
    func test_flood_recentEvents_requiresBaselineWhenCapExceeded() {
        let bus = EventBus(recentLimit: 512, recentByteLimit: EventBus.defaultRecentByteLimit)

        // each payload ~3 KB; 100 events = ~300 KB stored
        let chunk = String(repeating: "y", count: 3_000)
        for i in 0..<100 {
            bus.publishRawForTesting(kind: "big.\(i)", payload: .string(chunk))
        }

        // request replay with a cap much smaller than the stored payload
        let result = bus.recentEvents(since: 0, maxBytes: 1_024)

        XCTAssertTrue(result.requiresBaseline,
            "recentEvents() must set requiresBaseline when stored events exceed " +
            "the maxBytes cap; iOS must request a fresh snapshot to avoid showing " +
            "incomplete terminal/agent state after reconnect")
    }

    /// Replay sizing reads a cache that publish/trim mutate under the EventBus lock.
    /// Concurrent readers and publishers must complete without corrupting that cache.
    func test_recentEventsConcurrentWithPublishKeepsReplayOrdered() {
        let bus = EventBus(recentLimit: 64, recentByteLimit: 64 * 1_024)
        for index in 0..<64 {
            bus.publishRawForTesting(
                kind: "replay.seed.\(index)",
                payload: .string(String(repeating: "s", count: 200))
            )
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "eventbus.replay-race", attributes: .concurrent)
        for worker in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for index in 0..<256 {
                    if worker == 0 {
                        bus.publishRawForTesting(
                            kind: "replay.publish.\(index)",
                            payload: .string(String(repeating: "p", count: 200))
                        )
                    } else {
                        _ = bus.recentEvents(since: 0, maxBytes: 4 * 1_024)
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success,
                       "concurrent replay sizing and publish must not deadlock")
        let result = bus.recentEvents(since: 0, maxBytes: 4 * 1_024)
        XCTAssertEqual(result.events.map(\.seq), result.events.map(\.seq).sorted(),
                       "replay events must remain sequence ordered during concurrent publish")
    }

    func test_defaultRingKeepsContiguousPrefixAcrossDERPCatchUpRace() {
        let bus = EventBus()
        let chunk = String(repeating: "z", count: 32 * 1_024)
        for i in 0..<40 {
            bus.publishRawForTesting(kind: "relay-race.\(i)", payload: .string(chunk))
        }

        let firstPage = bus.recentEvents(since: 0, maxBytes: 512 * 1_024)

        XCTAssertEqual(firstPage.events.first?.seq, 1)
        XCTAssertFalse(firstPage.events.isEmpty)
        XCTAssertTrue(firstPage.requiresBaseline,
                      "the bounded first page remains pageable while more retained events follow")
    }

    // MARK: - LRU eviction preserves most-recent events

    /// When the count cap forces eviction the oldest events must be dropped and
    /// the most-recent ones must survive in the buffer.
    func test_flood_oldestEventsDroppedFirst() {
        let limit = 8
        let bus = EventBus(recentLimit: limit, recentByteLimit: 512 * 1024)

        // publish 2*limit events; only the last `limit` must survive
        for i in 0..<(limit * 2) {
            bus.publishRawForTesting(kind: "ev\(i)", payload: .number(Double(i)))
        }

        let (_, recent) = bus.snapshot()
        let seqs = recent.map(\.seq)

        // must have exactly `limit` events
        XCTAssertEqual(seqs.count, limit,
            "recent buffer must hold exactly recentLimit events after flood; got \(seqs.count)")

        // all retained events must have higher seq than the oldest dropped event
        let minRetainedSeq = seqs.min() ?? 0
        XCTAssertGreaterThan(minRetainedSeq, Int64(limit - 1),
            "oldest events (seq <= \(limit - 1)) must be evicted first; " +
            "keeping stale state over fresh state defeats the replay buffer's purpose")
    }

    func test_defaultRecentLimitsStayBoundedForDERPCatchUp() {
        XCTAssertEqual(EventBus.defaultRecentLimit, 4_096)
        XCTAssertEqual(EventBus.defaultRecentByteLimit, 2 * 1_024 * 1_024)
    }

    /// C18 WHY: terminal-output stand-ins (~100 B summaries) now share the
    /// ring, so a 128-event count cap covered ~1 s of a busy terminal and
    /// every resume needed a full snapshot. The count cap must leave room for
    /// seconds of small events while the byte cap stays the memory bound.
    func test_countCapCoversSecondsOfSmallEventsWithinByteBudget() {
        let limit = EventBus.defaultRecentLimit
        let summaryBytes = 128
        let eventsPerSecond = 100
        XCTAssertGreaterThanOrEqual(limit / eventsPerSecond, 30,
            "the ring must bridge a typical reconnect without a baseline")
        XCTAssertLessThanOrEqual(limit * summaryBytes, EventBus.defaultRecentByteLimit,
            "small events must not exceed the byte budget before the count cap trims")
    }

    func test_defaultRecentByteLimitCoversMultipleHealthyReplayWindows() {
        let limit = EventBus.defaultRecentByteLimit
        XCTAssertEqual(limit, 2 * 1_024 * 1_024)
        XCTAssertGreaterThanOrEqual(limit, 4 * 512 * 1_024)
    }

}
