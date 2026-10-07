import XCTest
@testable import SocketServer
import CoreModel

/// In-memory stand-in for the SQLite event log: stores what the persister
/// would write (every non-live-only event) and serves replay pages with the
/// same anchor rule as `EventLogRepository.readReplayPage`.
final class FakeDurableEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [EventBus.Event] = []
    private var unacknowledged: [Int64] = []
    var acknowledgeImmediately = true
    private(set) var pageReads = 0
    private(set) var estimateReads = 0
    private(set) var lastEstimateRowLimit: Int?

    func wire(_ bus: EventBus) {
        bus.durableReplaySource = EventBus.DurableReplaySource(page: { [self] after, through, limit in
            page(after: after, through: through, limit: limit)
        }, estimate: { [self] after, through, rowLimit in
            lock.lock(); defer { lock.unlock() }
            estimateReads += 1
            lastEstimateRowLimit = rowLimit
            guard rows.contains(where: { $0.seq <= after }) else { return (0, 0, false) }
            let range = rows.filter { $0.seq > after && $0.seq <= through }.prefix(rowLimit)
            return (range.count, range.reduce(0) { $0 + EventBus.retainedJSONByteCount($1) }, true)
        })
        bus.persister = { [weak bus, self] event in
            guard !EventBus.liveOnlyStreamEventKinds.contains(event.kind) else { return }
            lock.lock()
            rows.append(event)
            let ackNow = acknowledgeImmediately
            if !ackNow { unacknowledged.append(event.seq) }
            lock.unlock()
            if ackNow { bus?.acknowledgeDurablePersistence(sequences: [event.seq], succeeded: true) }
        }
    }

    static func unwire(_ bus: EventBus) {
        bus.persister = nil
        bus.durableReplaySource = nil
    }

    func acknowledgePending(_ bus: EventBus, succeeded: Bool = true) {
        lock.lock()
        let seqs = unacknowledged
        unacknowledged.removeAll()
        lock.unlock()
        bus.acknowledgeDurablePersistence(sequences: seqs, succeeded: succeeded)
    }

    func prune(through seq: Int64) {
        lock.lock(); rows.removeAll { $0.seq <= seq }; lock.unlock()
    }

    func page(after: Int64, through: Int64, limit: Int) -> EventBus.DurableReplaySourcePage {
        lock.lock(); defer { lock.unlock() }
        pageReads += 1
        let anchored = rows.contains { $0.seq <= after }
        let events = rows.filter { $0.seq > after && $0.seq <= through }.prefix(limit)
        return EventBus.DurableReplaySourcePage(events: Array(events), anchored: anchored)
    }
}

/// C8: the EventBus side of durable replay. Why it matters: iOS used to need
/// a full snapshot (about 300 KB) after any gap longer than the ~2 minute ring.
/// The bus must serve those cursors from the event log, name exactly the
/// streams whose live-only deltas were lost, and fall back to a baseline
/// whenever the log cannot prove it is complete — never replay a partial
/// history as if it were whole.
final class DurableReplayEventBusTests: XCTestCase {
    private func state(_ bus: EventBus, _ marker: String) {
        bus.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-1"), "name": .string(marker),
        ]))
    }

    private func delta(_ bus: EventBus, thread: String, text: String = "tok") {
        bus.publish(kind: .agentItemDelta, payload: .object([
            "thread_id": .string(thread), "item_id": .string("i-\(thread)"), "delta": .string(text),
        ]))
    }

    private func names(_ events: [EventBus.Event]) -> [String] {
        events.compactMap { $0.payload.objectValue?["name"]?.stringValue }
    }

    /// Cursor 2 after a busy period that pushed the cursor out of an 8-event ring.
    private func evictedScenario() -> (EventBus, FakeDurableEventLog, cursor: Int64) {
        let bus = EventBus(recentLimit: 8)
        let log = FakeDurableEventLog()
        log.wire(bus)
        state(bus, "anchor")               // 1
        delta(bus, thread: "t-before")     // 2: lost, but before the cursor
        let cursor = bus.currentSeq        // client saw through 2
        delta(bus, thread: "t-lost")       // 3
        state(bus, "s4")                   // 4
        delta(bus, thread: "t-lost")       // 5
        for index in 6...16 { state(bus, "s\(index)") }
        delta(bus, thread: "t-in-ring")    // 17: still retained
        return (bus, log, cursor)
    }

    func test_ringCoveredCursor_replaysRingOnly_withoutGaps() {
        let bus = EventBus(recentLimit: 100)
        let log = FakeDurableEventLog()
        log.wire(bus)
        state(bus, "a")
        let cursor = bus.currentSeq
        delta(bus, thread: "t-1")
        state(bus, "b")

        let plan = bus.durableReplayPlan(since: cursor)

        XCTAssertEqual(plan.outcome, .replay)
        XCTAssertEqual(plan.durableThrough, cursor, "the ring alone covers this cursor")
        XCTAssertEqual(plan.ringBacklog.map(\.seq), [cursor + 1, cursor + 2])
        XCTAssertTrue(plan.streamGaps.isEmpty)
        XCTAssertEqual(log.pageReads, 0)
    }

    func test_evictedRing_replaysStateFromLog_andGapsOnlyTheAffectedThread() throws {
        let (bus, _, cursor) = evictedScenario()

        let plan = bus.durableReplayPlan(since: cursor)

        XCTAssertEqual(plan.outcome, .replay)
        XCTAssertEqual(plan.head, 17)
        XCTAssertEqual(plan.durableThrough, 9, "ring keeps 10...17 after the last publish")
        XCTAssertEqual(plan.ringBacklog.map(\.seq), Array(10...17))
        XCTAssertEqual(plan.streamGaps, [
            EventBus.StreamGap(stream: .thread("t-lost"), sinceSequence: cursor, throughSequence: 5),
        ], "t-before lost a delta the client already had; t-in-ring lost nothing")

        let page = try XCTUnwrap(bus.readDurableReplayPage(
            after: cursor, through: plan.durableThrough, maxBytes: 1 << 20
        ))
        XCTAssertTrue(page.complete)
        XCTAssertEqual(page.events.map(\.seq), [4, 6, 7, 8, 9], "state events only; deltas are never in the log")
        XCTAssertEqual(names(page.events), ["s4", "s6", "s7", "s8", "s9"])

        let legacy = bus.recentEvents(since: cursor, maxBytes: nil)
        XCTAssertTrue(legacy.requiresBaseline, "clients that did not opt in keep today's baseline")
    }

    func test_logWritesNotYetAcknowledged_requireBaseline_untilPersisted() {
        let bus = EventBus(recentLimit: 4)
        let log = FakeDurableEventLog()
        log.acknowledgeImmediately = false
        log.wire(bus)
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for index in 0..<10 { state(bus, "s\(index)") }

        XCTAssertEqual(bus.durableReplayPlan(since: cursor).outcome, .baselineRequired,
                       "rows the writer has not committed cannot be replayed")

        log.acknowledgePending(bus)
        XCTAssertEqual(bus.durableReplayPlan(since: cursor).outcome, .replay)
    }

    func test_failedLogWrite_blocksCursorsBelowIt() {
        let bus = EventBus(recentLimit: 4)
        let log = FakeDurableEventLog()
        log.acknowledgeImmediately = false
        log.wire(bus)
        state(bus, "anchor")                // 1
        let cursor = bus.currentSeq
        state(bus, "lost-write")            // 2
        log.acknowledgePending(bus, succeeded: false)
        log.acknowledgeImmediately = true
        for index in 0..<10 { state(bus, "s\(index)") }

        XCTAssertEqual(bus.durableReplayPlan(since: cursor).outcome, .baselineRequired)
        XCTAssertEqual(bus.durableReplayPlan(since: 2).outcome, .replay,
                       "a cursor past the failed row is still complete")
    }

    func test_prunedLog_pageIsNil_soReplayFallsBack() {
        let (bus, log, cursor) = evictedScenario()
        log.prune(through: cursor)
        XCTAssertNil(bus.readDurableReplayPage(after: cursor, through: 9, maxBytes: 1 << 20),
                     "without a row at or below the cursor, retention may have dropped events")
    }

    func test_pages_respectMaxBytes_andAlwaysProgress() throws {
        let (bus, _, cursor) = evictedScenario()
        var after = cursor
        var seen: [Int64] = []
        var pages = 0
        while after < 9 {
            let page = try XCTUnwrap(bus.readDurableReplayPage(after: after, through: 9, maxBytes: 1))
            XCTAssertEqual(page.events.count, 1, "a page holds at least one event even over budget")
            seen += page.events.map(\.seq)
            after = page.coveredThrough
            pages += 1
        }
        XCTAssertEqual(seen, [4, 6, 7, 8, 9])
        XCTAssertEqual(pages, 5)
    }

    func test_lostStreamLedgerOverflow_requiresBaselineBelowItsFloor() {
        let bus = EventBus(recentLimit: 2)
        let log = FakeDurableEventLog()
        log.wire(bus)
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for index in 0...(EventBus.lostStreamLedgerLimit + 4) {
            delta(bus, thread: "t-\(index)")
        }
        XCTAssertEqual(bus.durableReplayPlan(since: cursor).outcome, .baselineRequired,
                       "a dropped ledger entry means a lost stream could go unreported")
        let late = bus.currentSeq - 3
        let plan = bus.durableReplayPlan(since: late)
        XCTAssertEqual(plan.outcome, .replay)
    }

    func test_durableRecentEvents_pagesTheLog_thenTheRing_withGaps() {
        let (bus, _, cursor) = evictedScenario()
        var since = cursor
        var seen: [Int64] = []
        var gaps = Set<EventBus.StreamGap.Stream>()
        for _ in 0..<20 {
            let (result, pageGaps) = bus.durableRecentEvents(since: since, maxBytes: 200)
            XCTAssertFalse(result.requiresBaseline)
            // A gap is reported while the page cursor is still before it.
            gaps.formUnion(pageGaps.map(\.stream))
            seen += result.events.map(\.seq)
            if !result.truncated { break }
            since = result.events.last!.seq
        }
        XCTAssertEqual(seen, [4, 6, 7, 8, 9] + Array(10...17))
        XCTAssertEqual(gaps, [.thread("t-lost")])
    }

    func test_replayBudget_onlyLimitsEventLogReplays() throws {
        let (bus, _, cursor) = evictedScenario()
        let logPlan = bus.durableReplayPlan(since: cursor)
        let estimate = try XCTUnwrap(bus.estimatedDurableReplayBytes(logPlan))
        XCTAssertFalse(bus.durableReplayExceedsBudget(logPlan, maxBytes: estimate))
        XCTAssertTrue(bus.durableReplayExceedsBudget(logPlan, maxBytes: estimate - 1),
                      "over budget a baseline is cheaper than replaying the log")
        let (result, gaps) = bus.durableRecentEvents(since: cursor, maxBytes: nil, replayBudgetBytes: estimate - 1)
        XCTAssertTrue(result.requiresBaseline)
        XCTAssertTrue(gaps.isEmpty)

        let ringPlan = bus.durableReplayPlan(since: 12)
        XCTAssertEqual(ringPlan.durableThrough, 12)
        XCTAssertFalse(bus.durableReplayExceedsBudget(ringPlan, maxBytes: 0),
                       "a ring-covered cursor replays like it does for every client")
    }

    // MARK: - Subscription gate

    func test_subscription_buffersLiveEventsUntilGoLive_thenKeepsOrder() {
        let bus = EventBus()
        let subscription = bus.subscribeDurableReplay(since: bus.currentSeq)
        defer { bus.unsubscribe(subscription.id) }
        state(bus, "a"); state(bus, "b")
        var received: [String] = []
        let lock = NSLock()
        let outcome = subscription.goLive(deliver: { item in
            guard case .event(let event) = item else { return }
            lock.lock(); received += self.names([event]); lock.unlock()
        }, onOverflow: { _ in XCTFail("no overflow expected") })
        XCTAssertEqual(outcome, .live)
        state(bus, "c")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(received, ["a", "b", "c"], "buffered events first, then live, in seq order")
    }

    func test_subscription_overflow_reportsNewestDroppedSeq_beforeLiveDelivery() {
        let bus = EventBus()
        let subscription = bus.subscribeDurableReplay(since: bus.currentSeq)
        defer { bus.unsubscribe(subscription.id) }
        let big = String(repeating: "x", count: 1_100_000)
        for _ in 0..<4 { delta(bus, thread: "t-big", text: big) }
        let lastDropped = bus.currentSeq
        var overflowAt: Int64?
        var received: [Int64] = []
        let outcome = subscription.goLive(deliver: { item in
            if case .event(let event) = item { received.append(event.seq) }
        }, onOverflow: { overflowAt = $0 })
        XCTAssertEqual(outcome, .overflowed(lastSequence: lastDropped))
        XCTAssertEqual(overflowAt, lastDropped)
        state(bus, "after")
        XCTAssertEqual(received, [lastDropped + 1], "live delivery resumes after the dropped range")
    }

    func test_goLive_overflowHandlerThatPublishesToTheBus_doesNotDeadlock_andKeepsOrder() {
        let bus = EventBus()
        let subscription = bus.subscribeDurableReplay(since: bus.currentSeq)
        defer { bus.unsubscribe(subscription.id) }
        let big = String(repeating: "x", count: 1_100_000)
        for _ in 0..<4 { delta(bus, thread: "t-big", text: big) }
        let through = bus.currentSeq
        let lock = NSLock()
        var received: [Int64] = []
        var outcome: DurableReplaySubscription.GoLiveOutcome?
        let done = expectation(description: "goLive returns")
        // HTTPServer's overflow handler can publish (pressure diagnostics);
        // that publish waits on the delivery queue, which delivers to this
        // very subscription. Holding its lock across the handler deadlocked.
        DispatchQueue.global().async {
            let result = subscription.goLive(deliver: { item in
                lock.lock(); received.append(item.sequence); lock.unlock()
            }, onOverflow: { _ in
                self.state(bus, "published-from-overflow")
                self.state(bus, "second")
            })
            lock.lock(); outcome = result; lock.unlock()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        state(bus, "live")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(outcome, .overflowed(lastSequence: through))
        XCTAssertEqual(received, [through + 1, through + 2, through + 3],
                       "events after the dropped range arrive once, in order, buffered then live")
    }

    // MARK: - Driver

    func test_driver_sendsGapsOnlyForStreamsTheSubscriberFilterCarries() {
        let (bus, _, cursor) = evictedScenario()
        delta(bus, thread: "t-other")
        for index in 18...30 { state(bus, "s\(index)") }   // evicts t-other's delta
        let cellular = bus.subscribeDurableReplay(
            since: cursor, filter: .cellularSafe(interestThreadIds: ["t-lost"])
        )
        let threadsOnly = bus.subscribeDurableReplay(since: cursor, filter: .agentThreadAndQueue)
        let full = bus.subscribeDurableReplay(since: cursor)
        defer { [cellular, threadsOnly, full].forEach { bus.unsubscribe($0.id) } }
        let allLost: Set<EventBus.StreamGap.Stream> = [.thread("t-lost"), .thread("t-in-ring"), .thread("t-other")]
        XCTAssertEqual(Set(full.plan.streamGaps.map(\.stream)), allLost)

        func gaps(_ subscription: DurableReplaySubscription) -> [EventBus.StreamGap.Stream] {
            var sent: [EventBus.StreamGap.Stream] = []
            let driver = DurableReplayDriver(
                sliceBytes: 1 << 20,
                firstPage: nil,
                readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
                deliverEvent: { _ in },
                deliverFiltered: { _ in },
                advanceWatermark: { _ in },
                isOpen: { true },
                waitForRoom: { _, _ in .ready },
                sendGap: { sent.append($0.stream); return true },
                requireBaseline: { _ in XCTFail("no baseline expected") }
            )
            guard case .completed(_, let count) = driver.run(subscription: subscription) else {
                XCTFail("expected completion"); return sent
            }
            XCTAssertEqual(count, sent.count)
            return sent
        }
        XCTAssertEqual(gaps(cellular), [.thread("t-lost")],
                       "t-other's deltas never reach this phone; a gap would only cost it a refetch")
        XCTAssertEqual(gaps(threadsOnly), [], "a socket that never carries deltas has nothing to refetch")
        XCTAssertEqual(Set(gaps(full)), allLost)
    }

    func test_driver_socketThatStopsDraining_getsBaselineAtHead_insteadOfWaitingForever() {
        let (bus, _, cursor) = evictedScenario()
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        var baselineAt: Int64?
        var timeouts: [TimeInterval] = []
        let driver = DurableReplayDriver(
            sliceBytes: 1,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { _ in },
            deliverFiltered: { _ in },
            advanceWatermark: { _ in },
            isOpen: { true },
            waitForRoom: { _, timeout in timeouts.append(timeout); return .stalled },
            sendGap: { _ in XCTFail("no gap after a baseline"); return true },
            requireBaseline: { baselineAt = $0 }
        )
        XCTAssertEqual(driver.run(subscription: subscription), .baselineRequired)
        XCTAssertEqual(baselineAt, 17)
        XCTAssertEqual(timeouts, [DurableReplayDriver.defaultStallTimeout], "one bounded wait, no polling loop")
    }

    func test_driver_skipsLiveOnlyHoles_thenAdvancesToHead_thenSendsGaps() {
        let (bus, _, cursor) = evictedScenario()
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        var log: [String] = []
        let driver = DurableReplayDriver(
            sliceBytes: 1 << 20,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { log.append("event \($0.seq)") },
            deliverFiltered: { log.append("filtered \($0)") },
            advanceWatermark: { log.append("advance \($0)") },
            isOpen: { true },
            waitForRoom: { _, _ in .ready },
            sendGap: { log.append("gap \($0.throughSequence)"); return true },
            requireBaseline: { log.append("baseline \($0)") }
        )

        let outcome = driver.run(subscription: subscription)

        XCTAssertEqual(outcome, .completed(eventsReplayed: 13, gapsSent: 1))
        XCTAssertEqual(log, [
            "advance 3", "event 4", "advance 5", "event 6", "event 7", "event 8", "event 9",
            "event 10", "event 11", "event 12", "event 13", "event 14", "event 15", "event 16",
            "event 17", "advance 17", "gap 5",
        ])
    }

    func test_driver_waitsForOutboundRoom_betweenSlices() {
        let (bus, _, cursor) = evictedScenario()
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        var queued = 0
        var waits = 0
        var deliveredWhileFull = 0
        let driver = DurableReplayDriver(
            sliceBytes: 1,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { _ in
                if queued > 1 { deliveredWhileFull += 1 }
                queued += 100
            },
            deliverFiltered: { _ in },
            advanceWatermark: { _ in },
            isOpen: { true },
            waitForRoom: { limit, _ in
                if queued > limit { waits += 1; queued = 0 }
                return .ready
            },
            sendGap: { _ in true },
            requireBaseline: { _ in XCTFail("no baseline expected") }
        )
        XCTAssertEqual(driver.run(subscription: subscription), .completed(eventsReplayed: 13, gapsSent: 1))
        XCTAssertEqual(deliveredWhileFull, 0, "no slice is queued until the previous one drained")
        XCTAssertEqual(waits, 13)
    }

    func test_driver_logPrunedMidReplay_fallsBackToBaselineAtHead() {
        let (bus, log, cursor) = evictedScenario()
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        let first = bus.readDurableReplayPage(after: cursor, through: 9, maxBytes: 1)
        log.prune(through: 6)
        var baselineAt: Int64?
        var gaps = 0
        let driver = DurableReplayDriver(
            sliceBytes: 1 << 20,
            firstPage: first,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { _ in },
            deliverFiltered: { _ in },
            advanceWatermark: { _ in },
            isOpen: { true },
            waitForRoom: { _, _ in .ready },
            sendGap: { _ in gaps += 1; return true },
            requireBaseline: { baselineAt = $0 }
        )
        XCTAssertEqual(driver.run(subscription: subscription), .baselineRequired)
        XCTAssertEqual(baselineAt, 17)
        XCTAssertEqual(gaps, 0, "no gap is reported once the client needs a baseline")
    }

    func test_driver_stopsWhenTheSocketCloses() {
        let (bus, _, cursor) = evictedScenario()
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        var delivered = 0
        let driver = DurableReplayDriver(
            sliceBytes: 1 << 20,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { _ in delivered += 1 },
            deliverFiltered: { _ in },
            advanceWatermark: { _ in },
            isOpen: { delivered < 2 },
            waitForRoom: { _, _ in delivered < 2 ? .ready : .closed },
            sendGap: { _ in XCTFail("closed socket gets no gap"); return true },
            requireBaseline: { _ in XCTFail("closed socket gets no baseline") }
        )
        XCTAssertEqual(driver.run(subscription: subscription), .closed)
        XCTAssertEqual(delivered, 2)
    }

    // MARK: - Contract

    func test_previousBootCursor_acceptedOnlyWithACleanRecord() {
        let previous = EventBus.PreviousBootReplay(
            bootEpoch: 6, highWater: 500, lostStreams: [:], minimumCursor: 0
        )
        func accept(_ since: Int64, epoch: Int64?, host: String? = "h", record: EventBus.PreviousBootReplay?) -> (Int64, Bool, Bool) {
            let result = DurableReplayContract.acceptedResume(
                requestedSinceSequence: since, requestedResumeHost: host,
                requestedResumeBootEpoch: epoch, serverId: "h", bootEpoch: 7,
                currentSequence: 600, previousBoot: record
            )
            return (result.since, result.previousBoot, result.eventLog)
        }
        XCTAssertTrue(accept(400, epoch: 6, record: previous) == (400, true, true))
        XCTAssertTrue(accept(400, epoch: 6, record: nil) == (0, false, false), "no record: baseline as before")
        XCTAssertTrue(accept(501, epoch: 6, record: previous) == (0, false, false), "past what that boot published")
        XCTAssertTrue(accept(400, epoch: 5, record: previous) == (0, false, false), "older epochs never resume")
        XCTAssertTrue(accept(400, epoch: 6, host: "other", record: previous) == (0, false, false))
        XCTAssertTrue(accept(550, epoch: 7, record: previous) == (550, false, true), "same boot works as before")
        XCTAssertTrue(accept(550, epoch: nil, host: nil, record: previous) == (550, false, false),
                      "legacy envelope-less cursor: same cursor, but its boot is unproven, so ring or baseline only")
    }

    func test_unprovenCursor_belowTheRing_getsBaseline_withoutReadingTheLog() {
        let (bus, log, cursor) = evictedScenario()
        XCTAssertEqual(bus.durableReplayPlan(since: cursor, allowEventLog: false).outcome, .baselineRequired,
                       "a cursor from a crashed boot could sit on log holes and lost deltas no ledger has")
        let ringPlan = bus.durableReplayPlan(since: 12, allowEventLog: false)
        XCTAssertEqual(ringPlan.outcome, .replay, "the ring still serves it, as before C8")
        XCTAssertEqual(ringPlan.durableThrough, 12)
        XCTAssertEqual(log.pageReads, 0)
        XCTAssertEqual(log.estimateReads, 0)
    }

    func test_freshConnect_sinceZero_getsBaseline_withoutAnyLogRead() {
        let (bus, log, _) = evictedScenario()
        let plan = bus.durableReplayPlan(since: 0)
        XCTAssertEqual(plan.outcome, .baselineRequired, "a client with no state needs the snapshot anyway")
        XCTAssertFalse(bus.durableReplayExceedsBudget(plan, maxBytes: 0), "no estimate for a baseline plan")
        XCTAssertEqual(log.pageReads, 0)
        XCTAssertEqual(log.estimateReads, 0)
    }

    func test_budgetEstimate_isBounded_andAnUnanchoredCursorExceedsIt() throws {
        let (bus, log, cursor) = evictedScenario()
        let plan = bus.durableReplayPlan(since: cursor)
        let full = try XCTUnwrap(bus.estimatedDurableReplayBytes(plan))
        let bounded = try XCTUnwrap(bus.estimatedDurableReplayBytes(plan, rowLimit: 1))
        XCTAssertLessThan(bounded, full, "the estimate stops reading at the row limit")
        // Every frame costs at least the overhead, so a 1,000-byte budget
        // never needs more than 1000 / 200 + 1 rows to know it is exceeded.
        _ = bus.durableReplayExceedsBudget(plan, maxBytes: 1_000)
        XCTAssertEqual(log.lastEstimateRowLimit, 6)
        _ = bus.durableReplayExceedsBudget(plan, maxBytes: DurableReplayContract.maximumReplayBytes)
        XCTAssertEqual(log.lastEstimateRowLimit, DurableReplayContract.maximumReplayBytes / 200 + 1)

        log.prune(through: cursor)
        XCTAssertNil(bus.estimatedDurableReplayBytes(plan), "retention passed the cursor")
        XCTAssertTrue(bus.durableReplayExceedsBudget(plan, maxBytes: .max), "baseline before any page read")
    }

    func test_streamGapFrame_roundTripsStrictly_andRejectsAmbiguousStream() throws {
        let data = try XCTUnwrap(DurableReplayContract.streamGapData(
            connectionId: "c", hostId: "h", bootEpoch: 3,
            gap: EventBus.StreamGap(stream: .thread("t-1"), sinceSequence: 10, throughSequence: 12)
        ))
        guard case .streamGap(let frame) = try ConnectionTransportFrame.decodeStrict(data) else {
            return XCTFail("expected streamGap")
        }
        XCTAssertEqual(frame.threadId, "t-1")
        XCTAssertNil(frame.surfaceId)
        XCTAssertEqual(frame.sinceSequence, 10)
        XCTAssertEqual(frame.throughSequence, 12)

        var both = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        both["surfaceId"] = "s-1"
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
            JSONSerialization.data(withJSONObject: both)
        ))

        let complete = try XCTUnwrap(DurableReplayContract.replayCompleteData(
            connectionId: "c", hostId: "h", bootEpoch: 3, throughSequence: 12
        ))
        guard case .replayComplete(let end) = try ConnectionTransportFrame.decodeStrict(complete) else {
            return XCTFail("expected replayComplete")
        }
        XCTAssertEqual(end.throughSequence, 12)
    }

    func test_ringDeltasOfAGappedThread_areSkipped_andExtendTheGap() {
        let bus = EventBus(recentLimit: 6)
        let log = FakeDurableEventLog()
        log.wire(bus)
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for _ in 0..<6 { delta(bus, thread: "t-long") }   // 2...7: 2 is evicted below
        delta(bus, thread: "t-fresh")                       // 8

        let plan = bus.durableReplayPlan(since: cursor)

        XCTAssertEqual(plan.outcome, .replay)
        XCTAssertEqual(plan.ringBacklog.map(\.seq), [8], "t-long's retained deltas are not resent")
        XCTAssertEqual(plan.streamGaps, [
            EventBus.StreamGap(stream: .thread("t-long"), sinceSequence: cursor, throughSequence: 7),
        ])
    }
}
