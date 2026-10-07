import XCTest
@testable import AppShell
import CoreModel
import SocketServer
import Persistence

final class EventBusPersistencePerformanceTests: XCTestCase {
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?

        func store(_ error: Error) {
            lock.lock()
            value = error
            lock.unlock()
        }

        func load() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct TimedSample {
        let producerWallNanoseconds: UInt64
        let durableWallNanoseconds: UInt64
    }

    @MainActor
    func test_productionPersisterReturnsBeforeBlockedWriterAndFlushesInOrder() throws {
        let context = try makeContext(label: "contract")
        let eventBus = EventBus(recentLimit: 0, recentByteLimit: 0)
        let writerEntered = expectation(description: "serial writer is blocked")
        let producerReturned = expectation(description: "producer returned without waiting for SQLite")
        let releaseWriter = DispatchSemaphore(value: 0)
        let deliveryEntered = DispatchSemaphore(value: 0)
        let releaseDelivery = DispatchSemaphore(value: 0)
        let flushStarted = DispatchSemaphore(value: 0)
        let flushReturned = DispatchSemaphore(value: 0)

        context.backgroundWriterQueue.async {
            writerEntered.fulfill()
            releaseWriter.wait()
        }
        wait(for: [writerEntered], timeout: 2)
        defer {
            releaseWriter.signal()
            for _ in 0..<4 { releaseDelivery.signal() }
        }

        AppDelegate.wireEventPersistence(context: context, eventBus: eventBus)
        let subscription = eventBus.subscribe(since: nil) { _ in
            deliveryEntered.signal()
            releaseDelivery.wait()
        }
        defer { eventBus.unsubscribe(subscription) }
        let payloads: [JSONValue] = (0..<3).map {
            .object(["ordinal": .number(Double($0))])
        }
        let firstSequence = eventBus.currentSeq + 1

        DispatchQueue.global(qos: .userInitiated).async {
            for payload in payloads {
                eventBus.publish(kind: .agentRunStarted, payload: payload)
            }
            producerReturned.fulfill()
        }

        XCTAssertEqual(deliveryEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            flushStarted.signal()
            eventBus.flushPersistenceSubmissions()
            flushReturned.signal()
        }
        XCTAssertEqual(flushStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flushReturned.wait(timeout: .now() + 0.05), .timedOut,
            "the lifecycle barrier must wait for a publish already accepted by the delivery queue")
        for _ in payloads { releaseDelivery.signal() }
        wait(for: [producerReturned], timeout: 2)
        XCTAssertEqual(flushReturned.wait(timeout: .now() + 2), .success)
        releaseWriter.signal()
        context.flushEventPersistence(eventBus: eventBus)

        let rows = try context.eventLog.read(since: firstSequence - 1, limit: payloads.count)
        XCTAssertEqual(rows.map(\.seq), Array(firstSequence..<(firstSequence + Int64(payloads.count))),
            "the serial writer must persist EventBus sequence order after the producer returns")
        XCTAssertEqual(rows.map(\.kind), Array(repeating: "agent.run.started", count: payloads.count))
        XCTAssertEqual(rows.map(\.payloadJSON), payloads.map(EventBus.encodePayloadForPersistence),
            "the lifecycle flush must make every queued payload durable without reordering")
    }

    @MainActor
    func test_persistedReceiptWritesEarlierEventFirstWithoutWaitingForUnrelatedWriterWork() throws {
        // WHY: command receipts write their events synchronously. If they can
        // pass an earlier normal event queued by the background persister, the
        // physical retention order diverges from EventBus sequence order. C6:
        // the fence must not get that order by draining the whole utility
        // writer queue either: unrelated work there (snapshot saves, storage
        // cleanup) used to hold every receipt, and the iPhone's mutation, for
        // as long as it ran.
        let context = try makeContext(label: "receipt-fence")
        let eventBus = EventBus(recentLimit: 0, recentByteLimit: 0)
        let writerEntered = expectation(description: "serial writer blocked by unrelated work")
        let releaseWriter = DispatchSemaphore(value: 0)
        let eventLog = context.eventLog

        context.backgroundWriterQueue.async {
            writerEntered.fulfill()
            releaseWriter.wait()
        }
        wait(for: [writerEntered], timeout: 2)
        defer { releaseWriter.signal() }

        AppDelegate.wireEventPersistence(context: context, eventBus: eventBus)
        eventBus.publish(kind: .agentRunStarted, payload: .string("normal"))

        let outcome = Self.commitReceipt(on: eventBus, eventLog: eventLog)
        XCTAssertEqual(
            outcome.returned.wait(timeout: .now() + 2),
            .success,
            "the receipt must not wait for unrelated work on the writer queue"
        )
        XCTAssertNil(outcome.error.load(), "the earlier normal event must already be durable inside the commit")
        XCTAssertEqual(try Self.physicalOrder(context), [1, 2],
            "physical retention order must match EventBus sequence order")

        releaseWriter.signal()
        context.flushEventPersistence(eventBus: eventBus)
        XCTAssertEqual(try Self.physicalOrder(context), [1, 2],
            "the writer's own flush must find the batch the fence wrote and not write it again")
        XCTAssertEqual(context.eventLogPersistedRowCountForTesting, 1, "the normal event is written exactly once")
    }

    @MainActor
    func test_persistedReceiptWaitsForTheInFlightEarlierEventBatch() throws {
        // WHY: a batch the writer already took holds earlier sequences. The
        // fence must wait for that batch's completion token, or the receipt's
        // events land before it.
        let context = try makeContext(label: "receipt-fence-in-flight")
        let eventBus = EventBus(recentLimit: 0, recentByteLimit: 0)
        let batchEntered = DispatchSemaphore(value: 0)
        let releaseBatch = DispatchSemaphore(value: 0)
        let eventLog = context.eventLog
        AppContext.beforeEventLogBatchWriteForTesting = {
            batchEntered.signal()
            releaseBatch.wait()
        }
        defer {
            AppContext.beforeEventLogBatchWriteForTesting = nil
            releaseBatch.signal()
        }

        AppDelegate.wireEventPersistence(context: context, eventBus: eventBus)
        eventBus.publish(kind: .agentRunStarted, payload: .string("normal"))
        XCTAssertEqual(batchEntered.wait(timeout: .now() + 2), .success, "the writer took the normal event's batch")

        let outcome = Self.commitReceipt(on: eventBus, eventLog: eventLog)
        XCTAssertEqual(
            outcome.returned.wait(timeout: .now() + 0.05),
            .timedOut,
            "the receipt must not pass the in-flight batch holding the earlier event"
        )
        AppContext.beforeEventLogBatchWriteForTesting = nil
        releaseBatch.signal()
        XCTAssertEqual(outcome.returned.wait(timeout: .now() + 2), .success)
        XCTAssertNil(outcome.error.load())
        XCTAssertEqual(try Self.physicalOrder(context), [1, 2],
            "physical retention order must match EventBus sequence order")
    }

    private static func commitReceipt(
        on eventBus: EventBus,
        eventLog: EventLogRepository
    ) -> (returned: DispatchSemaphore, error: ErrorBox) {
        let returned = DispatchSemaphore(value: 0)
        let commitError = ErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try eventBus.commitPersistedEvents { floor in
                    let durableBeforeReceipt = try eventLog.read(since: -1, limit: 10)
                    guard durableBeforeReceipt.map(\.seq) == [floor] else {
                        throw NSError(
                            domain: "EventBusPersistencePerformanceTests",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "receipt commit overtook the earlier normal event"]
                        )
                    }
                    let receipt = EventBus.Event(
                        seq: floor + 1,
                        kind: "command.receipt",
                        payload: .string("receipt"),
                        ts: 0
                    )
                    try eventLog.append(
                        seq: receipt.seq,
                        kind: receipt.kind,
                        payloadJSON: EventBus.encodePayloadForPersistence(receipt.payload)
                    )
                    return [receipt]
                }
            } catch {
                commitError.store(error)
            }
            returned.signal()
        }
        return (returned, commitError)
    }

    @MainActor
    private static func physicalOrder(_ context: AppContext) throws -> [Int64] {
        try context.db.performSync { sqlite -> [Int64] in
            let statement = try sqlite.prepare("SELECT seq FROM events ORDER BY id ASC;")
            var sequences: [Int64] = []
            while try statement.step() { sequences.append(statement.columnInt64(0)) }
            return sequences
        }
    }

    @MainActor
    func test_benchmarkBackgroundPersisterImprovesMedianProducerWallByMoreThanFivePercent() throws {
        guard ProcessInfo.processInfo.environment["RC2_EVENTBUS_PERSISTENCE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC2_EVENTBUS_PERSISTENCE_BENCHMARK=1 to run the EventBus A/B microbenchmark.")
        }

        let warmupCount = 2
        let measuredCount = 5
        let eventsPerSample = 32
        let synchronous = try makeHarness(label: "synchronous", background: false)
        let background = try makeHarness(label: "background", background: true)

        for warmup in 0..<warmupCount {
            _ = try measure(synchronous, sample: -warmup - 1, eventCount: eventsPerSample)
            _ = try measure(background, sample: -warmup - 1, eventCount: eventsPerSample)
        }

        var synchronousSamples: [TimedSample] = []
        var backgroundSamples: [TimedSample] = []
        for sample in 0..<measuredCount {
            if sample.isMultiple(of: 2) {
                synchronousSamples.append(try measure(synchronous, sample: sample, eventCount: eventsPerSample))
                backgroundSamples.append(try measure(background, sample: sample, eventCount: eventsPerSample))
            } else {
                backgroundSamples.append(try measure(background, sample: sample, eventCount: eventsPerSample))
                synchronousSamples.append(try measure(synchronous, sample: sample, eventCount: eventsPerSample))
            }
        }

        let synchronousProducer = synchronousSamples.map(\.producerWallNanoseconds)
        let backgroundProducer = backgroundSamples.map(\.producerWallNanoseconds)
        let synchronousDurable = synchronousSamples.map(\.durableWallNanoseconds)
        let backgroundDurable = backgroundSamples.map(\.durableWallNanoseconds)
        let synchronousMedian = median(synchronousProducer)
        let backgroundMedian = median(backgroundProducer)
        let improvementPercent = 100 * (Double(synchronousMedian) - Double(backgroundMedian))
            / Double(synchronousMedian)

        print("EVENTBUS_PERSISTENCE_BENCHMARK warmups=\(warmupCount) n=\(measuredCount) events_per_sample=\(eventsPerSample)")
        print("EVENTBUS_PERSISTENCE_BENCHMARK synchronous_producer_wall_ns=\(synchronousProducer)")
        print("EVENTBUS_PERSISTENCE_BENCHMARK background_producer_wall_ns=\(backgroundProducer)")
        print("EVENTBUS_PERSISTENCE_BENCHMARK synchronous_durable_wall_ns=\(synchronousDurable)")
        print("EVENTBUS_PERSISTENCE_BENCHMARK background_durable_wall_ns=\(backgroundDurable)")
        print("EVENTBUS_PERSISTENCE_BENCHMARK synchronous_producer_median_ns=\(synchronousMedian) background_producer_median_ns=\(backgroundMedian) improvement_percent=\(improvementPercent)")

        XCTAssertGreaterThan(improvementPercent, 5,
            "background persistence must improve median producer wall time by more than 5%")
    }

    @MainActor
    private func makeHarness(label: String, background: Bool) throws -> (context: AppContext, eventBus: EventBus) {
        let context = try makeContext(label: label)
        let eventBus = EventBus(recentLimit: 0, recentByteLimit: 0)
        if background {
            AppDelegate.wireEventPersistence(context: context, eventBus: eventBus)
        } else {
            let log = context.eventLog
            eventBus.persister = { event in
                guard AppDelegate.shouldPersistEvent(event) else { return }
                let json = EventBus.encodePayloadForPersistence(event.payload)
                _ = try? log.append(seq: event.seq, kind: event.kind, payloadJSON: json)
            }
        }
        context.flushWriterQueue()
        return (context, eventBus)
    }

    @MainActor
    private func measure(
        _ harness: (context: AppContext, eventBus: EventBus),
        sample: Int,
        eventCount: Int
    ) throws -> TimedSample {
        let payloads: [JSONValue] = (0..<eventCount).map { index in
            .object(["ordinal": .number(Double(sample * 1_000 + index))])
        }
        let firstSequence = harness.eventBus.currentSeq + 1
        let started = DispatchTime.now().uptimeNanoseconds
        for payload in payloads {
            harness.eventBus.publish(kind: .agentRunStarted, payload: payload)
        }
        let producerFinished = DispatchTime.now().uptimeNanoseconds
        harness.context.flushEventPersistence(eventBus: harness.eventBus)
        let durableFinished = DispatchTime.now().uptimeNanoseconds

        let rows = try harness.context.eventLog.read(since: firstSequence - 1, limit: eventCount)
        XCTAssertEqual(rows.map(\.seq), Array(firstSequence..<(firstSequence + Int64(eventCount))))
        XCTAssertEqual(rows.map(\.payloadJSON), payloads.map(EventBus.encodePayloadForPersistence),
            "every benchmark sample must prove persistence and order after the flush barrier")

        return TimedSample(
            producerWallNanoseconds: producerFinished - started,
            durableWallNanoseconds: durableFinished - started
        )
    }

    @MainActor
    func test_productionWiringKeepsReplayContiguousAcrossTerminalOutput() throws {
        // C18 WHY: every PTY chunk spends a global sequence but its base64 is
        // too large for the recent ring. If the ring simply skips it, the
        // replay floor collapses to head whenever any terminal printed after
        // the client's cursor, so every iOS resume / gap repair falls back to
        // a full sync.snapshot. The ring must keep a compact per-surface
        // refresh hint in the hole so cheap replay still works and the one
        // terminal refetches its own text.
        let context = try makeContext(label: "replay-contiguous")
        let eventBus = EventBus()
        AppDelegate.wireEventPersistence(context: context, eventBus: eventBus)
        defer { context.flushEventPersistence(eventBus: eventBus) }

        eventBus.publish(kind: .workspaceCreated, payload: .object([:]))
        let cursor = eventBus.currentSeq
        eventBus.publish(kind: .surfaceOutput, payload: .object([
            "surface_id": .string("surface-1"),
            "seq": .number(7),
            "base64": .string(String(repeating: "x", count: 4_096)),
        ]))
        eventBus.publish(kind: .workspaceUpdated, payload: .object([:]))

        let replay = eventBus.recentEvents(since: cursor, maxBytes: nil)
        XCTAssertFalse(replay.requiresBaseline,
            "terminal output after the cursor must not force a full baseline")
        XCTAssertEqual(replay.events.map(\.seq), [cursor + 1, cursor + 2],
            "replay must stay contiguous so iOS does not see an internal hole")
        XCTAssertEqual(replay.events.map(\.kind), ["surface.output.summary", "workspace.updated"])
        let summary = try XCTUnwrap(replay.events.first?.payload.objectValue)
        XCTAssertEqual(summary["surface_id"]?.stringValue, "surface-1")
        XCTAssertEqual(summary["seq"]?.intValue, 7,
            "iOS needs the per-surface sequence to refetch only that terminal")
        XCTAssertEqual(summary["partial"], .bool(true))
        XCTAssertNil(summary["base64"], "the ring must not pin raw terminal bytes")

        var expired = false
        var resumed: [String] = []
        let subscription = eventBus.subscribeDetectingReplayExpiry(
            since: cursor,
            onReplayExpired: { _ in expired = true },
            { resumed.append($0.kind) }
        )
        defer { eventBus.unsubscribe(subscription) }
        XCTAssertFalse(expired, "a WS resume across terminal output must not send baselineRequired")
        XCTAssertEqual(resumed, ["surface.output.summary", "workspace.updated"])
    }

    @MainActor
    private func makeContext(label: String) throws -> AppContext {
        let fallback = FileManager.default.temporaryDirectory.path
        let root = ProcessInfo.processInfo.environment["RC2_SANDBOX_APP_SUPPORT"] ?? fallback
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("EventBusPersistenceTests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try AppContext(channel: .debug, appSupportOverride: directory.path)
    }

    private func median(_ values: [UInt64]) -> UInt64 {
        values.sorted()[values.count / 2]
    }
}
