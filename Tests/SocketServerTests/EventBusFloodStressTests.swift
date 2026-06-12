import XCTest
@testable import SocketServer

/// QA item :80 — EventBus flood stress: buffer-bound assertions.
///
/// WHY: an unbounded recent buffer is a memory DoS vector. A single fast publisher
/// can grow recent[] and recentBytes without limit if trimRecent() is not invoked
/// on every publish path.  These tests drive EventBus directly (in-process) with
/// >512 events / >2 MB of payload and assert:
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
            bus.publish(kind: "flood", payload: .number(Double(i)))
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
        let byteLimit = 2 * 1024 * 1024   // 2 MB — matches the production default
        let bus = EventBus(recentLimit: 4096, recentByteLimit: byteLimit)

        // each payload ~4 KB; 600 events = ~2.4 MB raw, well above the 2 MB cap
        let chunk = String(repeating: "x", count: 4_000)
        for i in 0..<600 {
            bus.publish(kind: "flood.\(i)", payload: .string(chunk))
        }

        let bytes = bus.recentBytesForTests
        XCTAssertLessThanOrEqual(bytes, byteLimit,
            "recentBytes (\(bytes)) exceeds recentByteLimit (\(byteLimit)); " +
            "a 2 MB flood must not pin more than 2 MB in the in-process buffer")
    }

    // MARK: - Both caps simultaneously (default limits, >512 events)

    /// Publish 600 events (> default recentLimit=512) with small payloads and
    /// assert both count and byte invariants hold simultaneously.
    func test_flood_defaultLimits_countAndByteBothBounded() {
        // use default limits to verify production config is correctly wired
        let bus = EventBus()   // recentLimit=512, recentByteLimit=2 MB

        for i in 0..<600 {
            bus.publish(kind: "e\(i)", payload: .number(Double(i)))
        }

        let count = bus.recentCountForTests
        let bytes = bus.recentBytesForTests

        XCTAssertLessThanOrEqual(count, 512,
            "recent count (\(count)) exceeds default recentLimit=512 after 600-event flood")
        XCTAssertLessThanOrEqual(bytes, 2 * 1024 * 1024,
            "recentBytes (\(bytes)) exceeds default recentByteLimit=2MB after 600-event flood")
    }

    // MARK: - requiresBaseline flag

    /// After flooding the bus, recentEvents() with a tight maxBytes cap must set
    /// requiresBaseline so iOS knows it cannot replay from cache alone and must
    /// fetch a fresh snapshot instead of showing partial/stale state.
    func test_flood_recentEvents_requiresBaselineWhenCapExceeded() {
        let bus = EventBus(recentLimit: 512, recentByteLimit: 2 * 1024 * 1024)

        // each payload ~3 KB; 100 events = ~300 KB stored
        let chunk = String(repeating: "y", count: 3_000)
        for i in 0..<100 {
            bus.publish(kind: "big.\(i)", payload: .string(chunk))
        }

        // request replay with a cap much smaller than the stored payload
        let result = bus.recentEvents(since: 0, maxBytes: 1_024)

        XCTAssertTrue(result.requiresBaseline,
            "recentEvents() must set requiresBaseline when stored events exceed " +
            "the maxBytes cap; iOS must request a fresh snapshot to avoid showing " +
            "incomplete terminal/agent state after reconnect")
    }

    // MARK: - LRU eviction preserves most-recent events

    /// When the count cap forces eviction the oldest events must be dropped and
    /// the most-recent ones must survive in the buffer.
    func test_flood_oldestEventsDroppedFirst() {
        let limit = 8
        let bus = EventBus(recentLimit: limit, recentByteLimit: 512 * 1024)

        // publish 2*limit events; only the last `limit` must survive
        for i in 0..<(limit * 2) {
            bus.publish(kind: "ev\(i)", payload: .number(Double(i)))
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
}
