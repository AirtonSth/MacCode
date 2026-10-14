import XCTest
@testable import SocketServer

/// The replay ring evicts its oldest event on every publish once it is full.
/// WHY: eviction used `Array.removeFirst()`, which shifts the whole 4,096-event
/// window on each publish (under `lock`, often on the main actor through
/// `deliveryQueue.sync`). Eviction must be O(1) while replay order, the replay
/// floor and the count/byte caps stay exactly as before.
final class EventBusReplayRingTests: XCTestCase {
    func test_fullRingReplaysTheNewestWindowOldestFirst() {
        let limit = 64
        let bus = EventBus(recentLimit: limit, recentByteLimit: 512 * 1_024)
        for index in 0..<(limit * 5 + 3) {
            bus.publishRawForTesting(kind: "flood", payload: .number(Double(index)))
        }
        let lastSeq = bus.currentSeq
        let expected = Array((lastSeq - Int64(limit) + 1)...lastSeq)

        let recent = bus.recentEvents(since: 0, maxBytes: nil)
        XCTAssertEqual(recent.events.map(\.seq), expected, "replay must be the newest window, oldest first")
        XCTAssertTrue(recent.requiresBaseline, "a cursor below the evicted prefix cannot replay")
        let inWindow = bus.recentEvents(since: expected[9], maxBytes: nil)
        XCTAssertEqual(inWindow.events.map(\.seq), Array(expected.dropFirst(10)))
        XCTAssertFalse(inWindow.requiresBaseline, "a cursor inside the window replays without a baseline")
        XCTAssertEqual(bus.healthCounters().oldestRetainedSeq, expected.first)
        XCTAssertEqual(bus.snapshotMetadata().oldestReplaySequence, expected.first)

        var backlog: [Int64] = []
        let id = bus.subscribe(since: expected[19]) { backlog.append($0.seq) }
        bus.unsubscribe(id)
        XCTAssertEqual(backlog, Array(expected.dropFirst(20)), "subscribe backlog keeps ring order")
    }

    func test_byteCapAndOversizeFrameKeepTheSameWindow() {
        let bus = EventBus(recentLimit: 4_096, recentByteLimit: 64 * 1_024)
        let chunk = String(repeating: "x", count: 1_000)
        for _ in 0..<500 {
            bus.publishRawForTesting(kind: "flood", payload: .string(chunk))
        }
        XCTAssertLessThanOrEqual(bus.recentBytesForTests, 64 * 1_024)
        let window = bus.recentEvents(since: 0, maxBytes: nil).events.map(\.seq)
        XCTAssertEqual(window, Array((bus.currentSeq - Int64(window.count) + 1)...bus.currentSeq),
                       "byte-driven eviction drops only the oldest events")

        // A frame larger than the whole window replaces it; later events append after it.
        bus.publishRawForTesting(kind: "huge", payload: .string(String(repeating: "y", count: 70 * 1_024)))
        let hugeSeq = bus.currentSeq
        XCTAssertEqual(bus.recentEvents(since: 0, maxBytes: nil).events.map(\.seq), [hugeSeq])
        bus.publishRawForTesting(kind: "after", payload: .number(1))
        XCTAssertEqual(bus.recentEvents(since: 0, maxBytes: nil).events.map(\.seq), [bus.currentSeq],
                       "the next small event evicts the oversize frame by bytes, as before")
    }

    /// The ring must read exactly like the array it replaced across wraparound,
    /// growth and clears, or replay would reorder or resurrect evicted events.
    func test_ringMatchesArrayModelAcrossWrapGrowthAndClear() {
        var ring = EventReplayRing<Int>()
        var model: [Int] = []
        var generator = SystemRandomNumberGenerator()
        var next = 0
        for step in 0..<20_000 {
            switch Int.random(in: 0..<10, using: &generator) {
            case 0..<6:
                ring.append(next); model.append(next); next += 1
            case 6..<9 where !model.isEmpty:
                XCTAssertEqual(ring.removeFirst(), model.removeFirst())
            case 9 where step % 997 == 0:
                ring.removeAll(); model.removeAll()
            default:
                break
            }
            XCTAssertEqual(ring.count, model.count)
            XCTAssertEqual(ring.first, model.first)
        }
        XCTAssertEqual(Array(ring), model)
        XCTAssertEqual(Array(ring.reversed()), Array(model.reversed()))
        XCTAssertEqual(Array(EventReplayRing(model.shuffled().sorted())), model.sorted())
    }

    /// Interleaved A/B of the eviction step alone (old `[Event]` +
    /// `removeFirst()` vs the ring) on the same events, so host load hits both.
    func test_bench_fullWindowEvictionArrayVersusRing() {
        let window = EventBus.defaultRecentLimit
        let events = (0..<(window + 20_000)).map {
            EventBus.Event(seq: Int64($0), kind: "flood", payload: .number(Double($0)), ts: 0)
        }
        func runArray() -> Double {
            var recent: [EventBus.Event] = Array(events[..<window])
            let start = DispatchTime.now().uptimeNanoseconds
            for event in events[window...] {
                recent.append(event)
                _ = recent.removeFirst()
            }
            precondition(recent.count == window)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func runRing() -> Double {
            var recent = EventReplayRing(events[..<window])
            let start = DispatchTime.now().uptimeNanoseconds
            for event in events[window...] {
                recent.append(event)
                _ = recent.removeFirst()
            }
            precondition(recent.count == window)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let samples = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        _ = runArray(); _ = runRing()  // warm
        var arrayMs: [Double] = [], ringMs: [Double] = []
        for _ in 0..<samples {
            arrayMs.append(runArray())
            ringMs.append(runRing())
        }
        func line(_ name: String, _ values: [Double]) -> String {
            let median = values.sorted()[values.count / 2]
            let rendered = values.map { String(format: "%.2f", $0) }.joined(separator: ",")
            return "PERF_BENCH name=\(name) median_ms=\(String(format: "%.2f", median)) samples_ms=[\(rendered)]"
        }
        print(line("eventbus.evict20k.arrayRemoveFirst", arrayMs))
        print(line("eventbus.evict20k.replayRing", ringMs))
        XCTAssertLessThan(ringMs.sorted()[samples / 2], arrayMs.sorted()[samples / 2],
                          "O(1) eviction must beat shifting the whole window")
    }

    func test_bench_publishIntoFullDefaultRing() {
        let bus = EventBus()
        for index in 0..<EventBus.defaultRecentLimit {
            bus.publishRawForTesting(kind: "flood", payload: .number(Double(index)))
        }
        let samples = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        let publishes = 10_000
        var timings: [Double] = []
        for sample in 0...samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<publishes {
                bus.publishRawForTesting(kind: "flood", payload: .number(Double(index)))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if sample > 0 { timings.append(elapsed) }  // sample 0 warms up
        }
        XCTAssertEqual(bus.recentCountForTests, EventBus.defaultRecentLimit)
        let median = timings.sorted()[timings.count / 2]
        let rendered = timings.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=eventbus.publish10kFullRing median_ms=\(String(format: "%.2f", median)) samples_ms=[\(rendered)]")
    }
}
