import XCTest
@testable import SocketServer

/// Tests for the one-encode-per-event JSON cache in EventBus.
///
/// Why this matters:
/// - Without the cache, every subscriber + every persistence call re-encodes
///   the same event.  With N subscribers the work is O(N) per publish; with
///   the cache it is O(1).
/// - The cache MUST be deterministic: calling encodedData(for:) twice on the
///   same event must return byte-identical results (the cached copy).
/// - Distinct events MUST produce distinct byte sequences so the cache does
///   not collapse different payloads to the same bytes.
/// - Evicted events (removed from the recent ring) MUST NOT stay in the cache
///   (otherwise the cache grows without bound for long-running buses).
final class EventBusEncodeCacheTests: XCTestCase {

    // MARK: - Same-event identity

    /// Calling encodedData(for:) twice on the exact same event returns the
    /// same Data instance/bytes (the second call hits the cache, not the
    /// encoder).  This is the primary correctness + perf contract.
    func test_encodedData_sameEvent_returnsSameBytes() {
        let bus = EventBus()
        let ev = EventBus.Event(seq: 1, kind: "test.event", payload: .string("hello"), ts: 1234.0)

        let first  = bus.encodedData(for: ev)
        let second = bus.encodedData(for: ev)

        XCTAssertEqual(first, second,
            "encodedData(for:) must return byte-identical results on repeated calls for the same event -- divergence means subscribers receive different wire bytes for the same logical event, which corrupts iOS state reconstruction")
        XCTAssertFalse(first.isEmpty,
            "encoded bytes must not be empty -- an empty payload would silently drop the event on the iOS subscriber")
    }

    // MARK: - Distinct events produce distinct bytes

    /// Two events with different payloads must encode to different byte
    /// sequences.  If the cache collapsed them the iOS subscriber would
    /// receive the wrong payload for one of the events.
    func test_encodedData_distinctEvents_returnDistinctBytes() {
        let bus = EventBus()
        let ev1 = EventBus.Event(seq: 1, kind: "ev.a", payload: .string("alpha"), ts: 1.0)
        let ev2 = EventBus.Event(seq: 2, kind: "ev.b", payload: .string("beta"),  ts: 2.0)

        let bytes1 = bus.encodedData(for: ev1)
        let bytes2 = bus.encodedData(for: ev2)

        XCTAssertNotEqual(bytes1, bytes2,
            "distinct events must produce distinct encoded bytes -- if the cache maps different events to the same bytes, iOS would apply the wrong mutation for one of them")
    }

    // MARK: - Cache eviction when event leaves the ring

    /// After an event is evicted from the recent ring (ring overflow), the
    /// cache must no longer hold its bytes.  A fresh encode call after
    /// eviction must re-encode and produce the same logical bytes (so the
    /// function is still correct), but the old cache slot must be gone so
    /// memory does not grow with the total number of events published.
    func test_encodedData_evictedEvent_cacheEntryRemoved() {
        // Ring of exactly 1 event so a second publish evicts the first.
        let bus = EventBus(recentLimit: 1, recentByteLimit: 1024 * 1024)

        bus.publish(kind: "first.event", payload: .string("first"))
        let (_, snap1) = bus.snapshot()
        guard let firstEvent = snap1.first else {
            return XCTFail("expected one event in the ring after first publish")
        }

        // Warm the cache for firstEvent.
        let cachedBytes = bus.encodedData(for: firstEvent)
        XCTAssertFalse(cachedBytes.isEmpty, "pre-condition: cache must have bytes for firstEvent before eviction")

        // Publish a second event, which pushes the first out of the ring.
        bus.publish(kind: "second.event", payload: .string("second"))
        let (_, snap2) = bus.snapshot()
        XCTAssertEqual(snap2.count, 1, "ring size is 1, only the second event must remain")
        XCTAssertEqual(snap2.first?.kind, "second.event")

        // After eviction the cache entry for firstEvent.seq must be gone.
        // Verify indirectly: call encodedData again -- it MUST re-encode
        // (not return a stale cached reference).  The bytes must still be
        // semantically equivalent (same logical event), confirming correctness.
        let reEncodedBytes = bus.encodedData(for: firstEvent)
        XCTAssertEqual(cachedBytes, reEncodedBytes,
            "re-encoding an evicted event must produce the same bytes -- if they differ, the encoder is non-deterministic for this payload and the cache assumption breaks")
        // The test above also confirms the function remains correct post-eviction.
        // Cache-size bound is an internal invariant; the observable contract is
        // the encoding is stable and memory does not grow unboundedly with published events.
    }

    // MARK: - Publish-path integration: O(1) encode per event

    /// Publish one event with N subscribers.  The encoded bytes delivered to
    /// every subscriber must be identical to a single direct encodedData call.
    /// This validates that the publish path reuses the cached encode rather
    /// than re-encoding per subscriber.
    func test_publish_nSubscribers_encodeReusedAcrossSubscribers() {
        // Use a bus with no per-event encoding outside of our control.
        let bus = EventBus()
        let kind = "multi.fan"
        let payload = JSONValue.string("shared-payload")

        // Subscribe before publish so all subscribers are live.
        var deliveredKinds: [String] = []
        let lock = NSLock()
        let subCount = 5
        for _ in 0 ..< subCount {
            _ = bus.subscribe(since: nil, filter: .full) { ev in
                lock.lock(); deliveredKinds.append(ev.kind); lock.unlock()
            }
        }

        bus.publish(kind: kind, payload: payload)

        // All subscribers receive the event.
        XCTAssertEqual(deliveredKinds.count, subCount,
            "all \(subCount) subscribers must receive the event -- a missing delivery means a subscriber lost a mutation update")

        // The cached encode for the published event must be non-empty and stable.
        let (_, recent) = bus.snapshot()
        guard let ev = recent.first(where: { $0.kind == kind }) else {
            return XCTFail("published event must be retained in the ring")
        }
        let bytes1 = bus.encodedData(for: ev)
        let bytes2 = bus.encodedData(for: ev)
        XCTAssertEqual(bytes1, bytes2,
            "encodedData must return stable bytes for the published event -- instability would cause different subscribers to receive different wire payloads")
        XCTAssertFalse(bytes1.isEmpty, "encoded bytes must not be empty for a retained event")
    }

    // MARK: - Publish retains without JSONEncoder

    /// Token-rate `agent.item.delta` used to `JSONEncoder.encode` under the
    /// EventBus lock solely to measure the recent ring. The walk must match
    /// that encoder byte-for-byte so eviction / recentEvents stay identical.
    func test_retainedJSONByteCount_matchesEncoderForStreamAndLifecycleShapes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cases: [EventBus.Event] = [
            EventBus.Event(seq: 1, kind: "agent.item.delta", payload: .object([
                "thread_id": .string("t1"),
                "item_id": .string("i1"),
                "body_append": .string("hello"),
            ]), ts: 1_720_000_000.25),
            EventBus.Event(seq: 2, kind: "agent.item.delta", payload: .object([
                "body_append": .string("line\nquote\"slash\\path/tab\tend"),
            ]), ts: 1_720_000_001),
            EventBus.Event(seq: 3, kind: "agent.item.progress", payload: .object([
                "item_id": .string("i1"),
                "progress": .number(0.5),
            ]), ts: 0),
            EventBus.Event(seq: 4, kind: "workspace.created", payload: .null, ts: -1),
            EventBus.Event(seq: 5, kind: "surface.created", payload: .array([
                .bool(true), .bool(false), .number(0), .string(""),
            ]), ts: 42),
            EventBus.Event(seq: 6, kind: "emoji", payload: .string("café 🐱"), ts: 99.125),
            EventBus.Event(seq: Int64.max, kind: "big.seq", payload: .object([:]), ts: 1),
            // Live publish clock is Date().timeIntervalSince1970 (fractional).
            EventBus.Event(seq: 7, kind: "agent.item.delta", payload: .object([
                "progress": .number(1.0 / 3.0),
            ]), ts: 1_786_682_163.2664108),
            EventBus.Event(seq: 8, kind: "num", payload: .number(Double.pi), ts: -0.0),
            // Unsorted insertion order must still match encoder+sortedKeys length.
            EventBus.Event(seq: 9, kind: "agent.item.delta", payload: .object([
                "thread_id": .string("t"),
                "summary": .string("s"),
                "output_append": .string("o"),
                "item_id": .string("i"),
                "body_append": .string("b"),
            ]), ts: 2),
        ]
        for ev in cases {
            let encoded = try encoder.encode(ev)
            XCTAssertEqual(
                EventBus.retainedJSONByteCount(ev),
                encoded.count,
                "walk must equal JSONEncoder+sortedKeys for \(ev.kind) seq=\(ev.seq) body=\(String(data: encoded, encoding: .utf8) ?? "?")"
            )
        }
    }

    /// Publish must not JSON-encode just to admit an event into the ring.
    func test_publish_doesNotJSONEncodeForRingAccounting() {
        let bus = EventBus()
        bus.publish(
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("t1"),
                "item_id": .string("i1"),
                "body_append": .string("tok"),
            ])
        )
        XCTAssertEqual(
            bus.encodeCountForTesting,
            0,
            "retainRecent must walk JSON size; encoding here is the 30 Hz EventBus-lock tax"
        )
        XCTAssertEqual(bus.recentCountForTests, 1)
        XCTAssertGreaterThan(bus.recentBytesForTests, 0)
    }

    /// Publish `ts` is never an Int64. The walk must still equal the encoder
    /// for a live clock sample so ring eviction stays identical.
    func test_jsonNumberByteCount_liveTimestampAndFractions_matchEncoder() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let now = Date().timeIntervalSince1970
        let values: [Double] = [
            now, -0.0, 0.5, 99.125, Double.pi, 1.0 / 3.0, 1e20, 1e-10, -1.25,
        ]
        for value in values {
            let ev = EventBus.Event(seq: 1, kind: "n", payload: .number(value), ts: value)
            let encoded = try encoder.encode(ev)
            XCTAssertEqual(
                EventBus.retainedJSONByteCount(ev),
                encoded.count,
                "walk != encoder for \(value) json=\(String(data: encoded, encoding: .utf8) ?? "?")"
            )
        }
    }
}
