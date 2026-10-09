import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// C00 ruler, Mac half: the WebSocket frames and payload bytes that one
/// phone-started Bot run of 1,000 tokens costs a device, on the full stream
/// (Wi-Fi) and on the cellular-safe one, as the host is now.
///
/// WHY it matters: every frame is one socket write here and one MainActor hop
/// on the phone, and on cellular the bytes are the owner's data plan. The
/// counts are pinned, so a change to the tick cadence, the coalescing window
/// or the merge rule has to change a number in this file on purpose.
///
/// The run is replayed, not timed, so the counts are exact on a loaded
/// machine: a real `EventBus` sequences the events and applies the socket's
/// filter (the Bot's thread is the on-screen interest, as the Bot chat
/// registers it), a `WebSocketEventBatcher` built the way `DirectHTTPServer`
/// builds it receives them, and `flush()` stands in for each window timer.
/// One `sendKnownEvent` call is one WebSocket message; bytes are the encoded
/// frames, before WebSocket framing. The outbound queue's pressure path
/// (shedding, merging queued deltas) is not exercised.
///
/// `BotRuntimeEvidenceProjector` lives in AppShell, which this target does
/// not link, so the test publishes the `bot.run.stream` ticks itself, at the
/// cadence pinned by `BotRuntimeEvidenceProjectorTests`
/// (`test_thousandDeltasOverTwentySecondsPublishAtMostOneStreamTickPerSecond`).
/// A projector that ticks at another cadence does not fail this file.
///
/// Not repeated here: that the first delta of a reply leaves ahead of the
/// cellular window is counted by `WebSocketBatchWindowTests`
/// (`test_firstDeltaAfterIdle_leavesWithoutWaitingForTheWindow` and the tests
/// after it). That changes when the first frame leaves, not how many leave.
final class BotStreamFrameBaselineTests: XCTestCase {
    private static let deltaCount = 1_000
    /// Provider tokens 20 ms apart: 20 s of output for one bound run.
    private static let tokenIntervalMs = 20
    /// The projector ticks at once and then at most once per second
    /// (`BotRuntimeEvidenceProjector.streamTickInterval`): one tick behind
    /// every 50th delta, 20 for the run.
    private static let deltasPerLivenessTick = 1_000 / tokenIntervalMs
    private static let samples = 5

    private static let cellularSafe = EventStreamFilter.cellularSafe(
        interestThreadIds: [BotStreamFixture.threadID]
    )

    func test_fullStream_sendsEveryDeltaAndEveryTickAsItsOwnFrame() throws {
        // WHY: the Wi-Fi window (15 ms) is shorter than the gap between two
        // tokens, so no two deltas ever share one. A 1,000-token answer costs
        // one frame per token plus one per liveness tick, and nothing a
        // device receives was merged. With these ids a delta frame is about
        // 0.42 KB and a tick about 0.57 KB.
        let runs = try sample(filter: .full, deltasPerTick: Self.deltasPerLivenessTick)

        XCTAssertEqual(
            runs,
            Array(repeating: StreamCost(events: 1_020, frames: 1_020, tickFrames: 20,
                                        mergedAway: 0, bytes: 438_079),
                  count: Self.samples),
            "full stream, 1,000 deltas and 20 ticks: 1,020 frames and 438,079 bytes, the same on every run"
        )
    }

    func test_cellularSafeStream_mergesTheDeltasOfEachWindowIntoOneFrame() throws {
        // WHY: on cellular five tokens land in each 100 ms window and leave as
        // one frame, so the answer costs about a quarter of the Wi-Fi frames
        // and bytes. A tick between two deltas keeps them apart, so each of
        // the 19 later ticks costs its window two extra frames:
        // 1 (first delta) + 2 (first tick, rest of window 1)
        // + 19 x 3 (delta, tick, rest) + 180 x 1 (untouched windows) = 240.
        let runs = try sample(filter: Self.cellularSafe, deltasPerTick: Self.deltasPerLivenessTick)

        XCTAssertEqual(
            runs,
            Array(repeating: StreamCost(events: 1_020, frames: 240, tickFrames: 20,
                                        mergedAway: 780, bytes: 109_051),
                  count: Self.samples),
            "cellular-safe stream, 1,000 deltas and 20 ticks: 240 frames and 109,051 bytes, the same on every run"
        )
    }

    func test_tickBehindEveryDelta_costsTwoFramesPerTokenOnBothStreams() throws {
        // WHY: the two counts above depend on how often the projector ticks,
        // and this target cannot see the projector. With one tick per token
        // (the projector's cadence before `streamTickInterval`) the tick
        // flushes the Wi-Fi window and sits between every pair of deltas on
        // cellular, so nothing merges on either stream. This is today's
        // batcher fed that cadence, not a measurement of an older build. It
        // is the case to read when this file is run on a tree whose projector
        // ticks once per token.
        for filter in [EventStreamFilter.full, Self.cellularSafe] {
            let runs = try sample(filter: filter, deltasPerTick: 1)

            XCTAssertEqual(
                runs,
                Array(repeating: StreamCost(events: 2_000, frames: 2_000, tickFrames: 1_000,
                                            mergedAway: 0, bytes: 996_679),
                      count: Self.samples),
                "\(filter): a tick behind every delta leaves 2,000 frames and 996,679 bytes, the same on every run"
            )
        }
    }

    private func sample(filter: EventStreamFilter, deltasPerTick: Int) throws -> [StreamCost] {
        try (0..<Self.samples).map { _ in
            try replayRun(filter: filter, deltasPerTick: deltasPerTick)
        }
    }

    /// One Bot run through a fresh bus and batcher. Asserts what must hold on
    /// any stream (no token lost, no sequence unaccounted for) and returns
    /// the counts.
    private func replayRun(filter: EventStreamFilter, deltasPerTick: Int) throws -> StreamCost {
        // Tokens that land in one window before its timer closes it: one on
        // Wi-Fi (15 ms window, 20 ms tokens), five on cellular (100 ms).
        let windowMs = DirectHTTPServer.negotiateCoalescingWindowMs(filter: filter, proposedMs: nil)
        let deltasPerWindow = max(1, windowMs / Self.tokenIntervalMs)

        // Fixed clock: the event timestamp is part of every frame's bytes.
        let bus = EventBus(clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let recorder = BotStreamFrameRecorder()
        // As `DirectHTTPServer` builds it, except that only `flush()` closes
        // a window: the cellular window timer (30 s) and the age cap (60 s)
        // are far longer than the test. The 15 ms Wi-Fi timer is real and
        // cannot be injected; with one token per window, a timer that fires
        // early or late sends the same single delta, so no count depends on it.
        let batcher = WebSocketEventBatcher(
            enabled: filter.isCellularSafe,
            filter: filter,
            delay: 30,
            coalescesStreamingDeltas: true,
            maxPendingAge: 60,
            onCoalescedAway: { recorder.mergedAway($0) },
            onAdmissionOverflow: { lost, _ in recorder.overflowed(lost) },
            sendKnownEvent: { recorder.send($0) }
        )
        defer { batcher.stop() }
        let subscription = bus.subscribe(since: bus.currentSeq, filter: filter) { event in
            guard let known = event.knownEvent else { return }
            recorder.noteDelivered()
            batcher.enqueue(KnownConnectionEventFrame(
                event: known,
                connectionId: BotStreamFixture.connectionID,
                hostId: BotStreamFixture.hostID,
                bootEpoch: 7
            ))
        }
        defer { bus.unsubscribe(subscription) }

        let tokens = (1...Self.deltaCount).map { "t\($0) " }
        var published = 0
        for (index, token) in tokens.enumerated() {
            // Same payload shape as the host publishes: no `turn_id`.
            bus.publish(kind: .agentItemDelta, payload: .object([
                "thread_id": .string(BotStreamFixture.threadID),
                "item_id": .string(BotStreamFixture.itemID),
                "run_id": .string(BotStreamFixture.runID),
                "body_append": .string(token),
            ]))
            published += 1
            if index % deltasPerTick == 0 {
                // The projector's tick is the next sequence after its delta.
                bus.publish(kind: .botRunStream, payload: .object(BotStreamFixture.tickPayload))
                published += 1
            }
            if (index + 1) % deltasPerWindow == 0 { batcher.flush() }
        }
        batcher.flush()

        let held = batcher.admissionSnapshot()
        let sent = recorder.sent()
        let sentSequences = sent.map(\.event.seq)
        XCTAssertEqual(recorder.deliveredCount(), published,
                       "the filter must pass every delta of the on-screen Bot thread and every tick, or the counts measure the filter")
        XCTAssertEqual(held.count, 0, "nothing may stay buffered after the last window closed")
        XCTAssertEqual(held.overflowCount, 0, "the run must fit admission, or the counts prove nothing")
        XCTAssertEqual(recorder.lostSequences(), [], "no frame may be dropped by admission")
        XCTAssertEqual(sent.compactMap { $0.event.payload["body_append"]?.stringValue }.joined(),
                       tokens.joined(),
                       "the phone must receive every token exactly once, in order")
        XCTAssertEqual(sentSequences, sentSequences.sorted(), "frames must leave in sequence order")
        XCTAssertEqual((sentSequences + recorder.mergedSequences()).sorted(),
                       Array(Int64(1)...Int64(published)),
                       "each sequence is either sent or reported merged, never both and never neither")

        let bytes = try sent.reduce(0) { total, frame in try total + frame.encoded().count }
        return StreamCost(
            events: recorder.deliveredCount(),
            frames: sent.count,
            tickFrames: sent.filter { $0.event.kind == .botRunStream }.count,
            mergedAway: recorder.mergedSequences().count,
            bytes: bytes
        )
    }
}

// MARK: - Helpers

private struct StreamCost: Equatable {
    /// Events the socket's filter passed to the batcher.
    let events: Int
    /// WebSocket messages sent.
    let frames: Int
    /// How many of them were `bot.run.stream`.
    let tickFrames: Int
    /// Sequences folded into a later delta frame.
    let mergedAway: Int
    /// Encoded bytes of the frames sent.
    let bytes: Int
}

/// Ids are UUID-length, as the host's are, so the byte counts have the
/// proportions of a real run. The totals belong to these exact strings.
private enum BotStreamFixture {
    static let connectionID = "C0FFEE00-0000-4000-8000-00000000C001"
    static let hostID = "5E57E400-0000-4000-8000-00000000A001"
    static let threadID = "7a11ead0-0000-4000-8000-0000000000a1"
    static let itemID = "17e00000-0000-4000-8000-0000000000b1"
    static let runID = "2b900000-0000-4000-8000-0000000000c1"
    static let botID = "b0700000-0000-4000-8000-0000000000d1"
    static let conversationID = "c0900000-0000-4000-8000-0000000000e1"
    static let requestID = "2e900000-0000-4000-8000-0000000000f1"

    /// The six ids `BotRuntimeEvidenceProjector` puts in a `bot.run.stream`.
    static let tickPayload: [String: JSONValue] = [
        "host_id": .string(hostID),
        "bot_id": .string(botID),
        "conversation_id": .string(conversationID),
        "request_id": .string(requestID),
        "client_request_id": .string(requestID),
        "run_id": .string(runID),
    ]
}

private final class BotStreamFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredEvents = 0
    private var frames: [KnownConnectionEventFrame] = []
    private var merged: [Int64] = []
    private var lost: [Int64] = []

    func noteDelivered() {
        lock.lock(); deliveredEvents += 1; lock.unlock()
    }

    func send(_ frame: KnownConnectionEventFrame) {
        lock.lock(); frames.append(frame); lock.unlock()
    }

    func mergedAway(_ sequence: Int64) {
        lock.lock(); merged.append(sequence); lock.unlock()
    }

    func overflowed(_ sequences: [Int64]) {
        lock.lock(); lost.append(contentsOf: sequences); lock.unlock()
    }

    func deliveredCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return deliveredEvents
    }

    func sent() -> [KnownConnectionEventFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func mergedSequences() -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return merged
    }

    func lostSequences() -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return lost
    }
}
