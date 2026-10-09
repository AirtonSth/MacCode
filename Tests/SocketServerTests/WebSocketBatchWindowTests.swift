import XCTest
import RemoteCodeTreaty
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
/// - Keyed events must remain one-for-one and in arrival order:
///   dropping an intermediate event creates an unrecoverable sequence gap.
///
/// - Keyed and nil-key events in the same window retain global arrival order:
///   the reducer consumes one ordered sequence across all event kinds.
///
/// - When batching is disabled (`enabled: false`) nil-key events send immediately:
///   the cross-kind window must not activate when batching is turned off.
///
/// - The first agent.item.delta after an idle window leaves at once (leading edge):
///   the first character of a reply had nothing to coalesce with, yet waited the
///   whole cellular window. Only that one delta is early; the rest still merge,
///   so a reply costs at most one extra frame per idle gap.
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

    func test_keyedEvents_preserveEverySequenceInArrivalOrder() {
        // WHY: last-write-wins would remove an event sequence and force the
        // client into baseline recovery despite a healthy socket.
        let old = Data("old".utf8)
        let new = Data("new".utf8)
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            ("k1", old, 0.000),
            ("k1", new, 0.005),
        ]
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0], [old, new],
                       "two keyed events must both be delivered in arrival order")
    }

    func test_mixedKeyedAndNilKey_sameWindow_preservesArrivalOrder() {
        // WHY: the event cursor is global; grouping by key before delivery would
        // reorder sequence numbers across event kinds.
        let keyed = Data("keyed".utf8)
        let nilKey = Data("nil".utf8)
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            (nil,  nilKey, 0.000),
            ("k1", keyed,  0.005),
        ]
        let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        XCTAssertEqual(groups.count, 1,
                       "keyed and nil-key events within the same window must flush together")
        XCTAssertEqual(groups[0], [nilKey, keyed],
                       "mixed frames must retain their global arrival order")
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

    func test_CONN003_batchPermutations_neverDropOrReorderSequences() {
        // WHY: last-write-wins keyed batching silently removes event sequences;
        // replay cursors cannot advance safely across a frame that was never sent.
        let permutations: [[(String?, Int64)]] = [
            [("surface:1", 1043), (nil, 1044), ("surface:1", 1045)],
            [(nil, 1043), ("surface:1", 1044), ("surface:2", 1045), (nil, 1046)],
            [("surface:1", 1043), ("surface:2", 1044), ("surface:1", 1045)],
        ]

        for permutation in permutations {
            let events = permutation.enumerated().map { index, item in
                (key: item.0,
                 data: Data("\(item.1)".utf8),
                 t: TimeInterval(index) * 0.001)
            }
            let groups = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
            let delivered = groups.flatMap { $0 }.compactMap { Int64(String(decoding: $0, as: UTF8.self)) }
            XCTAssertEqual(delivered, permutation.map(\.1),
                           "every accepted sequence must be delivered once in arrival order")
        }
    }

    // MARK: - Leading edge: first agent.item.delta after an idle window
    //
    // These count frames instead of timing them. `admissionSnapshot()` is a
    // `queue.sync` on the batcher queue, so once it returns every earlier
    // enqueue has run and whatever was going to leave without a timer has left.

    func test_firstDeltaAfterIdle_leavesWithoutWaitingForTheWindow() {
        // WHY: on cellular the first character of every reply sat on the Mac for
        // the whole negotiated window (250 ms at the top of the clamp) although
        // nothing was there to merge with it. It must leave in the enqueue itself.
        let recorder = KnownFrameRecorder()
        let batcher = makeCellularBatcher(window: 0.250, recorder: recorder)
        defer { batcher.stop() }

        batcher.enqueue(makeDelta(sequence: 1, text: "H"))
        let held = batcher.admissionSnapshot()

        XCTAssertEqual(recorder.sentSequences(), [1],
                       "the first delta into an idle window must be sent by the enqueue, not by the window timer")
        XCTAssertEqual(held.count, 0,
                       "nothing may stay buffered behind a delta that already left")
    }

    func test_burstOf1000Deltas_leavesAsTwoFrames_theFirstAloneThenTheRestMerged() {
        // WHY: the leading edge may cost one extra frame per idle gap and no more.
        // If later tokens also left early, a cellular reply would go back to one
        // frame per token. The window is far longer than the test and `flush()`
        // stands in for its timer, so the counts do not depend on machine load.
        let recorder = KnownFrameRecorder()
        let batcher = makeCellularBatcher(window: 30, recorder: recorder)
        defer { batcher.stop() }
        let tokens = (1...1_000).map { "t\($0) " }

        for (index, token) in tokens.enumerated() {
            batcher.enqueue(makeDelta(sequence: Int64(index + 1), text: token))
        }
        let held = batcher.admissionSnapshot()

        XCTAssertEqual(recorder.sentSequences(), [1],
                       "only the first delta of a burst may leave ahead of the window")
        XCTAssertEqual(held.count, 999,
                       "every delta after the first must wait for the window so it can merge")
        XCTAssertEqual(held.overflowCount, 0, "the burst must fit admission, or the counts above prove nothing")

        batcher.flush()

        let sent = recorder.sent()
        XCTAssertEqual(sent.map(\.event.seq), [1, 1_000],
                       "1,000 deltas in one window are two frames: the leading one and one merged frame")
        XCTAssertEqual(sent.compactMap { $0.event.payload["body_append"]?.stringValue }.joined(),
                       tokens.joined(),
                       "the phone must still receive every token exactly once, in order")
        XCTAssertEqual(recorder.coalescedSequences(), Array(Int64(2)...999),
                       "merged sequences are still reported for gap accounting; the leading one is not merged away")
    }

    func test_deltaBehindTheLeadingOne_stillLeavesWhenTheWindowCloses() {
        // WHY: the leading flush empties the buffer without arming a timer. The
        // next delta has to arm the window itself, or it would be stranded until
        // some unrelated event flushed it.
        let recorder = KnownFrameRecorder()
        let batcher = makeCellularBatcher(window: 0.05, recorder: recorder)
        defer { batcher.stop() }

        batcher.enqueue(makeDelta(sequence: 1, text: "a"))
        batcher.enqueue(makeDelta(sequence: 2, text: "b"))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, recorder.sentSequences().count < 2 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(recorder.sentSequences(), [1, 2],
                       "the delta behind the leading one must be delivered by the window timer, as its own frame")
    }

    func test_idleGapOfOneWindow_reopensTheLeadingEdge() {
        // WHY: every pause in a reply (a tool call, a slow provider) ends with a
        // "first token" too. Once nothing was flushed for a whole window, the
        // next delta must be immediate again, not only the first of the connection.
        let recorder = KnownFrameRecorder()
        let batcher = makeCellularBatcher(window: 0.02, recorder: recorder)
        defer { batcher.stop() }

        batcher.enqueue(makeDelta(sequence: 1, text: "a"))
        _ = batcher.admissionSnapshot()
        // Longer than the window; a sleep never returns early.
        Thread.sleep(forTimeInterval: 0.1)
        batcher.enqueue(makeDelta(sequence: 2, text: "b"))
        let held = batcher.admissionSnapshot()

        XCTAssertEqual(recorder.sentSequences(), [1, 2],
                       "a delta arriving after a whole idle window must leave in its own enqueue")
        XCTAssertEqual(held.count, 0)
    }

    func test_frameWaitingAheadOfTheFirstDelta_leavesWithIt_inSequenceOrder() {
        // WHY: providers publish agent.item.started in the same breath as the
        // item's first delta, so on cellular that event is already waiting in
        // the window when the first token arrives. The token can only leave
        // early if the frames ahead of it leave first, never around them: the
        // phone reduces one ordered sequence.
        let recorder = KnownFrameRecorder()
        let batcher = makeCellularBatcher(window: 30, recorder: recorder)
        defer { batcher.stop() }

        batcher.enqueue(makeItemStarted(sequence: 1))
        XCTAssertEqual(batcher.admissionSnapshot().count, 1)
        XCTAssertEqual(recorder.sentSequences(), [],
                       "only a streaming delta opens the window early; other events keep waiting for it")

        batcher.enqueue(makeDelta(sequence: 2, text: "H"))
        XCTAssertEqual(batcher.admissionSnapshot().count, 0)
        XCTAssertEqual(recorder.sentSequences(), [1, 2],
                       "the first delta must leave at once, behind the frame that was waiting ahead of it")

        batcher.enqueue(makeDelta(sequence: 3, text: "i"))
        XCTAssertEqual(batcher.admissionSnapshot().count, 1)
        XCTAssertEqual(recorder.sentSequences(), [1, 2],
                       "a second delta inside the same window must wait: one early flush per idle gap")
    }

    func test_burstsSplitByIdleGaps_costOneExtraFramePerGap_andLoseNoSequence() {
        // WHY: a reply pauses (tool call, slow provider) and resumes many times.
        // Each resume may cost one early frame and no more, and the phone must
        // still account for every sequence in order. The clock is injected and
        // `flush()` stands in for the window timer, so the counts are exact on
        // a loaded machine.
        let recorder = KnownFrameRecorder()
        let clock = ManualUptime()
        let window: TimeInterval = 30
        let batcher = makeCellularBatcher(window: window, recorder: recorder, uptime: { clock.now() })
        defer { batcher.stop() }
        let tokens = (1...1_000).map { "t\($0) " }
        let bursts = 4
        let perBurst = tokens.count / bursts

        for burst in 0..<bursts {
            for offset in 0..<perBurst {
                let index = burst * perBurst + offset
                batcher.enqueue(makeDelta(sequence: Int64(index + 1), text: tokens[index]))
            }
            XCTAssertEqual(batcher.admissionSnapshot().count, perBurst - 1,
                           "burst \(burst): only its first delta may leave ahead of the window")
            batcher.flush()
            clock.advance(by: window)
        }

        let sent = recorder.sent()
        XCTAssertEqual(sent.map(\.event.seq), [1, 250, 251, 500, 501, 750, 751, 1_000],
                       "4 windows cost 4 merged frames; 4 idle gaps add exactly 4 leading frames")
        XCTAssertEqual(sent.compactMap { $0.event.payload["body_append"]?.stringValue }.joined(),
                       tokens.joined(),
                       "every token must reach the phone once, in order")
        XCTAssertEqual((sent.map(\.event.seq) + recorder.coalescedSequences()).sorted(),
                       Array(Int64(1)...1_000),
                       "each sequence is either sent or reported merged, never both and never neither")
        XCTAssertEqual(batcher.admissionSnapshot().overflowCount, 0)
    }

    func test_deltaLessThanOneWindowAfterAFlush_waitsAndMerges() {
        // WHY: the leading edge must not raise the steady frame rate. A delta
        // that arrives before one whole window has passed since the last frame
        // left has to wait and merge, exactly as before the change.
        let recorder = KnownFrameRecorder()
        let clock = ManualUptime()
        let window: TimeInterval = 30
        let batcher = makeCellularBatcher(window: window, recorder: recorder, uptime: { clock.now() })
        defer { batcher.stop() }

        batcher.enqueue(makeDelta(sequence: 1, text: "a"))
        _ = batcher.admissionSnapshot()
        clock.advance(by: window - 1)
        batcher.enqueue(makeDelta(sequence: 2, text: "b"))
        batcher.enqueue(makeDelta(sequence: 3, text: "c"))

        XCTAssertEqual(batcher.admissionSnapshot().count, 2,
                       "deltas inside the window opened by the leading one must be held")
        XCTAssertEqual(recorder.sentSequences(), [1])

        batcher.flush()
        XCTAssertEqual(recorder.sent().map { $0.event.payload["body_append"]?.stringValue }, ["a", "bc"],
                       "held deltas still merge into one frame when the window closes")
        XCTAssertEqual(recorder.sentSequences(), [1, 3])

        clock.advance(by: window)
        batcher.enqueue(makeDelta(sequence: 4, text: "d"))
        XCTAssertEqual(batcher.admissionSnapshot().count, 0)
        XCTAssertEqual(recorder.sentSequences(), [1, 3, 4],
                       "one whole window after the last frame left, the next delta is a first token again")
    }

    func test_deltaOneWindowAfterTheLastFlush_whileEarlierDeltasAreHeld_mergesBehindThem() {
        // WHY: the idle check measures from the last frame sent, but the window
        // timer starts at the first held delta, which comes later. A delta that
        // lands in between is one whole window after the last flush while
        // earlier deltas are still held: it must merge behind them. If it opened
        // the leading edge again, a bursty reply would flush twice per window
        // and send up to twice the frames it sent before the leading edge.
        let recorder = KnownFrameRecorder()
        let clock = ManualUptime()
        let window: TimeInterval = 30
        let batcher = makeCellularBatcher(window: window, recorder: recorder, uptime: { clock.now() })
        defer { batcher.stop() }

        batcher.enqueue(makeDelta(sequence: 1, text: "a"))
        XCTAssertEqual(batcher.admissionSnapshot().count, 0)
        XCTAssertEqual(recorder.sentSequences(), [1])

        // Each snapshot waits for the enqueue before it, so the clock only
        // moves between deltas, never under one.
        clock.advance(by: 10)
        batcher.enqueue(makeDelta(sequence: 2, text: "b"))
        _ = batcher.admissionSnapshot()
        clock.advance(by: 20)
        // Exactly one window since seq 1 left; the timer armed by seq 2 has 10 s to run.
        batcher.enqueue(makeDelta(sequence: 3, text: "c"))
        _ = batcher.admissionSnapshot()
        clock.advance(by: 5)
        batcher.enqueue(makeDelta(sequence: 4, text: "d"))

        XCTAssertEqual(batcher.admissionSnapshot().count, 3,
                       "a delta arriving while earlier deltas are held must be held too, however long ago the last frame left")
        XCTAssertEqual(recorder.sentSequences(), [1],
                       "no frame may leave between the leading one and the close of the window it opened")

        batcher.flush()
        XCTAssertEqual(recorder.sent().map { $0.event.payload["body_append"]?.stringValue }, ["a", "bcd"],
                       "the held deltas are one merged frame when the window closes")
        XCTAssertEqual(recorder.sentSequences(), [1, 4])

        clock.advance(by: window)
        batcher.enqueue(makeDelta(sequence: 5, text: "e"))
        XCTAssertEqual(batcher.admissionSnapshot().count, 0)
        XCTAssertEqual(recorder.sentSequences(), [1, 4, 5],
                       "once the window flushed and a whole window passed, the next delta is a first token again")
    }

    func test_overflowThatDropsTheHeldDeltas_doesNotKeepTheNextFirstTokenWaiting() {
        // WHY: admission overflow throws the held deltas away. Nothing is held
        // after it, so the next delta after an idle window is a first token and
        // must leave at once, not wait a window behind deltas that no longer exist.
        let recorder = KnownFrameRecorder()
        let clock = ManualUptime()
        let window: TimeInterval = 30
        let batcher = makeCellularBatcher(window: window, recorder: recorder,
                                          maxPendingCount: 3, uptime: { clock.now() })
        defer { batcher.stop() }

        batcher.enqueue(makeDelta(sequence: 1, text: "a"))
        _ = batcher.admissionSnapshot()
        for sequence in Int64(2)...4 {
            batcher.enqueue(makeDelta(sequence: sequence, text: "x"))
            // One at a time: the pre-queue bound is the same 3 frames.
            _ = batcher.admissionSnapshot()
        }
        XCTAssertEqual(batcher.admissionSnapshot().count, 3)

        clock.advance(by: window)
        batcher.enqueue(makeDelta(sequence: 5, text: "e"))
        let held = batcher.admissionSnapshot()

        XCTAssertEqual(held.overflowCount, 1, "the fourth held delta must overflow, or this test proves nothing")
        XCTAssertEqual(held.count, 0,
                       "after an overflow emptied the window, the next delta has nothing to wait behind")
        XCTAssertEqual(recorder.sentSequences(), [1, 5])
    }

    func test_leadingFlush_remembersTheWindowTimersAlreadyArmed() {
        // WHY: a terminal summary and agent.item.started that were waiting leave
        // early with the first delta, but the timers armed for them still fire.
        // If the batcher forgot them, the next delta would arm a second timer
        // and two timer chains would alternate for the rest of the reply: twice
        // the frames. The first delta right behind agent.item.started is the
        // normal start of every reply.
        let recorder = KnownFrameRecorder()
        let batcher = makeCellularBatcher(window: 30, recorder: recorder)
        defer { batcher.stop() }

        batcher.enqueue(makeTerminalSummary(sequence: 1))
        batcher.enqueue(makeItemStarted(sequence: 2))
        let before = batcher.windowTimerSnapshot()
        XCTAssertTrue(before.keyed && before.nilKey, "both waiting frames must have armed their window timer")

        batcher.enqueue(makeDelta(sequence: 3, text: "H"))
        XCTAssertEqual(batcher.admissionSnapshot().count, 0)
        XCTAssertEqual(recorder.sentSequences(), [1, 2, 3])

        let after = batcher.windowTimerSnapshot()
        XCTAssertTrue(after.nilKey,
                      "the un-keyed timer is still pending; forgetting it lets the next delta arm a second one")
        XCTAssertTrue(after.keyed,
                      "the keyed timer is still pending; forgetting it lets the next summary arm a second one")
    }

    /// The batcher as `HTTPServer` builds it for a `cellular-safe` socket, with
    /// admission bounds wide enough that only the window decides what leaves.
    private func makeCellularBatcher(
        window: TimeInterval,
        recorder: KnownFrameRecorder,
        maxPendingCount: Int = 2_000,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> WebSocketEventBatcher {
        WebSocketEventBatcher(
            enabled: true,
            filter: .cellularSafe(),
            delay: window,
            coalescesStreamingDeltas: true,
            maxPendingCount: maxPendingCount,
            maxPendingAge: 60,
            onCoalescedAway: { recorder.coalescedAway($0) },
            uptime: uptime,
            sendKnownEvent: { recorder.send($0) }
        )
    }

    /// Same payload shape as the host publishes: no `turn_id`, so the delta
    /// takes the un-keyed window like every real token.
    private func makeDelta(sequence: Int64, text: String) -> KnownConnectionEventFrame {
        makeFrame(sequence: sequence, kind: .agentItemDelta, payload: [
            "thread_id": .string("thread-1"),
            "item_id": .string("item-1"),
            "run_id": .string("run-1"),
            "body_append": .string(text),
        ])
    }

    private func makeItemStarted(sequence: Int64) -> KnownConnectionEventFrame {
        makeFrame(sequence: sequence, kind: .agentItemStarted, payload: [
            "thread_id": .string("thread-1"),
            "item": .object(["id": .string("item-1")]),
        ])
    }

    /// Keyed on `cellular-safe` (last write wins per surface), so it waits on
    /// the keyed window timer, not the un-keyed one.
    private func makeTerminalSummary(sequence: Int64) -> KnownConnectionEventFrame {
        makeFrame(sequence: sequence, kind: .surfaceOutputSummary, payload: [
            "surface_id": .string("surface-1"),
        ])
    }

    private func makeFrame(
        sequence: Int64,
        kind: RemoteCodeEventKind,
        payload: [String: JSONValue]
    ) -> KnownConnectionEventFrame {
        KnownConnectionEventFrame(
            event: EventBus.KnownEvent(seq: sequence, kind: kind, payload: payload, ts: 0),
            connectionId: "connection-1",
            hostId: "host-1",
            bootEpoch: 7
        )
    }
}

// MARK: - Helpers

private final class KnownFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [KnownConnectionEventFrame] = []
    private var coalesced: [Int64] = []

    func send(_ frame: KnownConnectionEventFrame) {
        lock.lock(); frames.append(frame); lock.unlock()
    }

    func coalescedAway(_ sequence: Int64) {
        lock.lock(); coalesced.append(sequence); lock.unlock()
    }

    func sent() -> [KnownConnectionEventFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func sentSequences() -> [Int64] {
        sent().map(\.event.seq)
    }

    func coalescedSequences() -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return coalesced
    }
}

private final class ManualUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); value += interval; lock.unlock()
    }
}

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
