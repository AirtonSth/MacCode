import XCTest
@testable import SocketServer

final class EventBusTests: XCTestCase {
    func test_publish_subscribe_replay() {
        let bus = EventBus()
        // local instance just for test (avoid bleeding state into shared)
        bus.publish(kind: "a", payload: .string("1"))
        bus.publish(kind: "b", payload: .string("2"))
        var received: [EventBus.Event] = []
        _ = bus.subscribe(since: 0) { received.append($0) }
        // backlog: 2 events
        XCTAssertEqual(received.map(\.kind), ["a", "b"])
        // live events
        bus.publish(kind: "c", payload: .number(3))
        XCTAssertEqual(received.map(\.kind), ["a", "b", "c"])
    }

    func test_since_filtersBacklog() {
        let bus = EventBus()
        bus.publish(kind: "a", payload: .null)
        bus.publish(kind: "b", payload: .null)
        bus.publish(kind: "c", payload: .null)
        var received: [EventBus.Event] = []
        _ = bus.subscribe(since: 2) { received.append($0) }
        XCTAssertEqual(received.map(\.kind), ["c"])
    }

    func test_liveOnlyEventsAreDeliveredButNotReplayed() {
        let bus = EventBus()
        bus.shouldRetainRecentEvent = { $0.kind != "surface.output" }
        var live: [String] = []
        _ = bus.subscribe(since: nil) { live.append($0.kind) }

        bus.publish(kind: "surface.output", payload: .string("chunk"))
        bus.publish(kind: "surface.created", payload: .null)

        var replayed: [String] = []
        _ = bus.subscribe(since: 0) { replayed.append($0.kind) }

        XCTAssertEqual(live, ["surface.output", "surface.created"],
                       "live terminal output must still reach active mirror subscribers")
        XCTAssertEqual(replayed, ["surface.created"],
                       "terminal output is high-volume mirror data and must not occupy the replay backlog")
    }

    func test_recentBacklogIsByteBounded() {
        let bus = EventBus(recentLimit: 512, recentByteLimit: 900)
        bus.publish(kind: "small.a", payload: .string(String(repeating: "a", count: 650)))
        bus.publish(kind: "huge", payload: .string(String(repeating: "x", count: 2_000)))
        bus.publish(kind: "small.b", payload: .string(String(repeating: "b", count: 650)))

        var replayed: [String] = []
        _ = bus.subscribe(since: 0) { replayed.append($0.kind) }

        XCTAssertEqual(replayed, ["small.b"],
                       "event replay must drop oversized/old payloads so one large RPC event cannot pin megabytes in memory")
    }

    func test_recentEventsReportsBaselineRequiredWhenReplayByteCapIsExceeded() {
        let bus = EventBus(recentLimit: 512, recentByteLimit: 20_000)
        bus.publish(kind: "surface.output", payload: .string(String(repeating: "x", count: 2_000)))
        bus.publish(kind: "surface.output", payload: .string(String(repeating: "y", count: 2_000)))

        let recent = bus.recentEvents(since: 0, maxBytes: 800)

        XCTAssertTrue(recent.requiresBaseline,
                      "when replay cannot prove complete terminal output, iOS must be told to fetch a snapshot or show partial state")
    }

    func test_webSocketOutboundQueueClosesSlowClientBeforeMemoryCanGrowUnbounded() {
        let closed = LockedStrings()
        let queue = WebSocketOutboundQueue(maxQueuedBytes: 8, writer: { _ in
            Thread.sleep(forTimeInterval: 0.03)
            return true
        }, onClose: { reason in
            closed.append(reason)
        })

        XCTAssertEqual(queue.enqueue(Data("12345678".utf8)), .accepted)
        XCTAssertEqual(queue.enqueue(Data("9".utf8)), .queueFull,
                       "a stalled iOS socket must be disconnected/downgraded instead of letting host terminal output queue forever")
        queue.drain()
        XCTAssertEqual(closed.values(), ["queue_full"])
    }

    func test_subscriberSnapshotConsistencyAfterAddAndRemove() {
        // WHY: publish iterates a cached snapshot instead of copying subscribers.values
        // on every call; the cache must reflect every add and every remove so no event
        // is delivered to a removed subscriber and no new subscriber is skipped.
        let bus = EventBus()

        var aReceived: [String] = []
        var bReceived: [String] = []

        let idA = bus.subscribe(since: nil) { aReceived.append($0.kind) }
        let idB = bus.subscribe(since: nil) { bReceived.append($0.kind) }

        bus.publish(kind: "e1", payload: .null)
        // both A and B must receive e1 (snapshot includes both after two adds)
        XCTAssertEqual(aReceived, ["e1"], "subscriber A missed event after add; snapshot not rebuilt on subscribe")
        XCTAssertEqual(bReceived, ["e1"], "subscriber B missed event after add; snapshot not rebuilt on subscribe")

        bus.unsubscribe(idA)
        bus.publish(kind: "e2", payload: .null)
        // A must NOT receive e2 (snapshot must have been rebuilt on unsubscribe)
        XCTAssertEqual(aReceived, ["e1"], "removed subscriber A still received event; snapshot not rebuilt on unsubscribe")
        XCTAssertEqual(bReceived, ["e1", "e2"], "subscriber B missed event after A was removed")

        bus.unsubscribe(idB)
        bus.publish(kind: "e3", payload: .null)
        // neither A nor B should receive e3 (empty snapshot)
        XCTAssertEqual(aReceived, ["e1"], "A received event after full unsubscribe")
        XCTAssertEqual(bReceived, ["e1", "e2"], "B received event after full unsubscribe")
    }

    @MainActor
    func test_dispatcher_eventsRecent_returnsBus() async {
        // publish to shared bus then query
        EventBus.shared.publish(kind: "test.kind", payload: .string("hello"))
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "events.recent", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        guard case .array(let evs) = o["events"]! else { return XCTFail() }
        XCTAssertFalse(evs.isEmpty)
    }
}

private final class LockedStrings {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    func values() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
