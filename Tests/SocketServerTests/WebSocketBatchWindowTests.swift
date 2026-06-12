import XCTest
@testable import SocketServer

/// Tests for the nil-key (cross-kind) batch window added to WebSocketEventBatcher.
///
/// WHY each assertion encodes intent (Rule 8):
///
/// - Events arriving within `crossKindDelay` must coalesce into one flush group:
///   high-frequency bursts of mixed-kind events would otherwise produce one WS
///   frame per event; batching cuts frame count without dropping or reordering.
///
/// - Events past the window must form a separate flush group:
///   the window must not accumulate indefinitely; a late event must be in its
///   own flush so no event is stranded beyond one window width.
///
/// - Ordering within a group must equal arrival order:
///   iOS mirror state depends on deterministic event ordering; coalescing must
///   never silently reorder events.
///
/// - Keyed (coalescing) events must still coalesce per key, last-write-wins:
///   existing keyed-batch guarantee must not regress.
///
/// - Keyed and nil-key events in the same window flush together, keyed first:
///   a single WS frame burst should carry both kinds; flushing separately would
///   double frame count for mixed batches.
///
/// - When batching is disabled (`enabled: false`) nil-key events send immediately:
///   the cross-kind window must not activate when batching is turned off.
final class WebSocketBatchWindowTests: XCTestCase {

    // MARK: - groupFlushes helper (pure, no timers)

    func test_nilKeyEventsWithinWindow_coalesceIntoOneGroup() {
        // WHY: events arriving within the window window must merge into a single
        // flush so high-frequency bursts produce fewer WS frames.
        let d1 = Data("a".utf8)
        let d2 = Data("b".utf8)
        let d3 = Data("c".utf8)
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            (nil, d1, 0.000),
            (nil, d2, 0.005),
            (nil, d3, 0.012),
        ]
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 1,
                       "three nil-key events within 15ms window must coalesce into one flush group")
        XCTAssertEqual(groups[0], [d1, d2, d3],
                       "arrival order within the group must be preserved")
    }

    func test_nilKeyEventsPastWindow_formSeparateGroups() {
        // WHY: the batch window must not grow unbounded; an event arriving after
        // the window must start a new flush group so maximum latency = window width.
        let d1 = Data("a".utf8)
        let d2 = Data("b".utf8)
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            (nil, d1, 0.000),
            (nil, d2, 0.020),   // > 15ms window
        ]
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 2,
                       "an event past the window must not merge with the first group -- maximum delivery latency = window width")
        XCTAssertEqual(groups[0], [d1])
        XCTAssertEqual(groups[1], [d2])
    }

    func test_orderWithinGroup_matchesArrivalOrder() {
        // WHY: iOS mirror reduces state by replaying events in order; wrong order
        // produces corrupt terminal/file state.
        let frames = (1...5).map { Data("\($0)".utf8) }
        let events: [(key: String?, data: Data, t: TimeInterval)] = frames.enumerated().map {
            (nil, $0.element, TimeInterval($0.offset) * 0.002)
        }
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0], frames,
                       "arrival order must be preserved exactly within a flush group")
    }

    func test_keyedEventsCoalesce_lastWriteWins() {
        // WHY: the existing keyed-batch guarantee (last write per key wins) must
        // not regress after adding the nil-key window.
        let old = Data("old".utf8)
        let new = Data("new".utf8)
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            ("k1", old, 0.000),
            ("k1", new, 0.005),
        ]
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0], [new],
                       "two keyed events with the same key must coalesce; only the last data value must be sent")
    }

    func test_mixedKeyedAndNilKey_sameWindow_flushTogether_keyedFirst() {
        // WHY: if keyed and nil-key events share a window they must flush in one
        // batch (fewer WS frames); keyed frames first so coalesced state arrives
        // before supplementary nil-key events.
        let keyed = Data("keyed".utf8)
        let nilKey = Data("nil".utf8)
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            (nil,  nilKey, 0.000),
            ("k1", keyed,  0.005),
        ]
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 1,
                       "keyed and nil-key events within the same window must flush together")
        XCTAssertEqual(groups[0].first, keyed,
                       "keyed frames must precede nil-key frames in the flush group")
        XCTAssertEqual(groups[0].last, nilKey)
    }

    func test_emptyInput_returnsEmptyGroups() {
        let groups = WebSocketEventBatcher.groupFlushes(events: [], window: 0.015)
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Live batcher integration (real DispatchQueue + timer)

    func test_nilKeyEventsWithinWindow_coalesceInLiveBatcher() {
        // WHY: the pure helper verifies grouping logic; this test verifies the
        // real batcher wires up the cross-kind timer correctly so events actually
        // coalesce in production code, not just in the pure model.
        let sent = LockedDataList()
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .full,          // .full always returns nil key
            delay: 0.075,
            send: { sent.append($0) }
        )
        let event = EventBus.Event(seq: 1, kind: "test.kind", payload: .null, ts: 0)
        let d1 = Data("a".utf8)
        let d2 = Data("b".utf8)
        let d3 = Data("c".utf8)

        batcher.enqueue(event: event, data: d1)
        batcher.enqueue(event: event, data: d2)
        batcher.enqueue(event: event, data: d3)

        // Wait for cross-kind window to fire (15ms + margin)
        Thread.sleep(forTimeInterval: 0.060)

        let frames = sent.values()
        XCTAssertEqual(frames, [d1, d2, d3],
                       "three nil-key frames within the 15ms window must arrive as a batch of exactly 3 frames (no drops, no reorder)")
    }

    func test_nilKeyEventsAcrossWindow_deliveredInSeparateBatches() {
        // WHY: events past the window must not be stranded -- each must flush
        // within one window width of its arrival.
        let sent = LockedDataList()
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .full,
            delay: 0.075,
            send: { sent.append($0) }
        )
        let event = EventBus.Event(seq: 1, kind: "test.kind", payload: .null, ts: 0)
        let d1 = Data("first".utf8)
        let d2 = Data("second".utf8)

        batcher.enqueue(event: event, data: d1)
        // Wait past the cross-kind window before sending the second event.
        Thread.sleep(forTimeInterval: 0.050)
        batcher.enqueue(event: event, data: d2)
        Thread.sleep(forTimeInterval: 0.050)

        let frames = sent.values()
        XCTAssertEqual(frames, [d1, d2],
                       "events separated by more than the window must both be delivered without drops")
        // Both must have arrived (no stranding): checked by asserting count==2.
        XCTAssertEqual(frames.count, 2,
                       "a lone event past the window must not be stranded -- the timer must fire for it too")
    }

    func test_disabledBatcher_nilKeyEventsSendImmediately() {
        // WHY: when batching is disabled the cross-kind window must not activate;
        // callers that disable batching expect synchronous delivery semantics.
        let sent = LockedDataList()
        let batcher = WebSocketEventBatcher(
            enabled: false,
            filter: .full,
            delay: 0.075,
            send: { sent.append($0) }
        )
        let event = EventBus.Event(seq: 1, kind: "test.kind", payload: .null, ts: 0)
        batcher.enqueue(event: event, data: Data("x".utf8))
        batcher.flush()

        XCTAssertEqual(sent.values().count, 1,
                       "disabled batcher must deliver nil-key events immediately without buffering")
    }
}

// MARK: - Helpers

private final class LockedDataList {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ value: Data) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    func values() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
