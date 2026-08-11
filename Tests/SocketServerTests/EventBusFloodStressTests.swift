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
        let byteLimit = EventBus.defaultRecentByteLimit  // 128 KiB production default
        let bus = EventBus(recentLimit: 4096, recentByteLimit: byteLimit)

        // each payload ~4 KB; 400 events = ~1.6 MB raw, well above the 128 KiB cap
        let chunk = String(repeating: "x", count: 4_000)
        for i in 0..<400 {
            bus.publish(kind: "flood.\(i)", payload: .string(chunk))
        }

        let bytes = bus.recentBytesForTests
        XCTAssertLessThanOrEqual(bytes, byteLimit,
            "recentBytes (\(bytes)) exceeds recentByteLimit (\(byteLimit)); " +
            "a multi-MB flood must not pin more than the production byte budget")
    }

    // MARK: - Both caps simultaneously (default limits, >512 events)

    /// Publish 600 events (> default recentLimit) with small payloads and
    /// assert both count and byte invariants hold simultaneously.
    func test_flood_defaultLimits_countAndByteBothBounded() {
        // use default limits to verify production config is correctly wired
        let bus = EventBus()
        let limit = EventBus.defaultRecentLimit
        let byteLimit = EventBus.defaultRecentByteLimit

        for i in 0..<600 {
            bus.publish(kind: "e\(i)", payload: .number(Double(i)))
        }

        let count = bus.recentCountForTests
        let bytes = bus.recentBytesForTests

        XCTAssertLessThanOrEqual(count, limit,
            "recent count (\(count)) exceeds default recentLimit=\(limit) after 600-event flood")
        XCTAssertLessThanOrEqual(bytes, byteLimit,
            "recentBytes (\(bytes)) exceeds default recentByteLimit after 600-event flood")
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

    func test_defaultRecentLimitIs128() {
        XCTAssertEqual(EventBus.defaultRecentLimit, 128)
        XCTAssertEqual(EventBus.defaultRecentByteLimit, 128 * 1024)
    }

    func test_retentionEstimate_256EventsTo128Window() {
        let uncapped = 256 // prior defaultRecentLimit
        let limit = EventBus.defaultRecentLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: typical EventBus payload + encode-cache entry ≈ 1KB.
        // Prior default 256 events (encode cache mirrors the ring).
        // 256 × 1KB ≈ 256KB → 128 × 1KB ≈ 128KB (−50%) for ring+cache keys;
        // recentByteLimit (128 KiB) still bounds large payloads.
        let perEvent = 1_024
        XCTAssertEqual(uncapped * perEvent, 262_144)
        XCTAssertEqual(limit * perEvent, 131_072)
    }

    func test_retentionEstimate_recentByteLimit_256KiBTo128KiB() {
        let prior = 256 * 1024 // prior defaultRecentByteLimit
        let limit = EventBus.defaultRecentByteLimit
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128 * 1024)

        // Basis: peak in-process EventBus recent[] payload retention.
        // 256 KiB → 128 KiB (−50%) after count already at 128.
        XCTAssertEqual(prior, 262_144)
        XCTAssertEqual(limit, 131_072)
        XCTAssertLessThan(limit, prior)
    }

}
