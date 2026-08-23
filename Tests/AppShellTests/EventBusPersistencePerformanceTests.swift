import XCTest
@testable import AppShell
import CoreModel
import SocketServer

final class EventBusPersistencePerformanceTests: XCTestCase {
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
                eventBus.publish(kind: "agent.run.started", payload: payload)
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
            harness.eventBus.publish(kind: "agent.run.started", payload: payload)
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
