import XCTest
@testable import SocketServer

final class EventBusTests: XCTestCase {
    func test_publish_subscribe_replay() {
        let bus = EventBus()
        // local instance just for test (avoid bleeding state into shared)
        bus.publishRawForTesting(kind: "a", payload: .string("1"))
        bus.publishRawForTesting(kind: "b", payload: .string("2"))
        var received: [EventBus.Event] = []
        _ = bus.subscribe(since: 0) { received.append($0) }
        // backlog: 2 events
        XCTAssertEqual(received.map(\.kind), ["a", "b"])
        // live events
        bus.publishRawForTesting(kind: "c", payload: .number(3))
        XCTAssertEqual(received.map(\.kind), ["a", "b", "c"])
    }

    func test_since_filtersBacklog() {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "a", payload: .null)
        bus.publishRawForTesting(kind: "b", payload: .null)
        bus.publishRawForTesting(kind: "c", payload: .null)
        var received: [EventBus.Event] = []
        _ = bus.subscribe(since: 2) { received.append($0) }
        XCTAssertEqual(received.map(\.kind), ["c"])
    }

    func test_liveOnlyEventsAreDeliveredButNotReplayed() {
        let bus = EventBus()
        bus.shouldRetainRecentEvent = { $0.kind != "surface.output" }
        var live: [String] = []
        _ = bus.subscribe(since: nil) { live.append($0.kind) }

        bus.publish(kind: .surfaceOutput, payload: .string("chunk"))
        bus.publish(kind: .surfaceCreated, payload: .null)

        var replayed: [String] = []
        _ = bus.subscribe(since: 0) { replayed.append($0.kind) }

        XCTAssertEqual(live, ["surface.output", "surface.created"],
                       "live terminal output must still reach active mirror subscribers")
        XCTAssertEqual(replayed, ["surface.created"],
                       "terminal output is high-volume mirror data and must not occupy the replay backlog")
    }

    func test_recentBacklogIsByteBounded() {
        let bus = EventBus(recentLimit: 512, recentByteLimit: 900)
        bus.publishRawForTesting(kind: "small.a", payload: .string(String(repeating: "a", count: 650)))
        bus.publishRawForTesting(kind: "huge", payload: .string(String(repeating: "x", count: 2_000)))
        bus.publishRawForTesting(kind: "small.b", payload: .string(String(repeating: "b", count: 650)))

        var replayed: [String] = []
        _ = bus.subscribe(since: 0) { replayed.append($0.kind) }

        XCTAssertEqual(replayed, ["small.b"],
                       "event replay must drop oversized/old payloads so one large RPC event cannot pin megabytes in memory")
    }

    func test_recentEventsReportsBaselineRequiredWhenReplayByteCapIsExceeded() {
        let bus = EventBus(recentLimit: 512, recentByteLimit: 20_000)
        bus.publish(kind: .surfaceOutput, payload: .string(String(repeating: "x", count: 2_000)))
        bus.publish(kind: .surfaceOutput, payload: .string(String(repeating: "y", count: 2_000)))

        let recent = bus.recentEvents(since: 0, maxBytes: 800)

        XCTAssertTrue(recent.requiresBaseline,
                      "when replay cannot prove complete terminal output, iOS must be told to fetch a snapshot or show partial state")
    }

    func test_webSocketOutboundQueueReportsFullWithoutClosingSlowClient() {
        // C-04: overflow is a degrade signal, not a hard close. Memory stays
        // bounded by the budget; the socket stays open so 3G clients can recover.
        let closed = LockedStrings()
        let queue = WebSocketOutboundQueue(maxQueuedBytes: 8, writer: { _ in
            Thread.sleep(forTimeInterval: 0.03)
            return true
        }, onClose: { reason in
            closed.append(reason)
        })

        XCTAssertEqual(queue.enqueue(Data("12345678".utf8)), .accepted)
        XCTAssertEqual(queue.enqueue(Data("9".utf8)), .queueFull,
                       "a stalled iOS socket must signal pressure instead of growing unbounded")
        XCTAssertEqual(closed.values(), [],
                       "queue_full must not terminate the connection (C-04)")
        let outcome = queue.degrade()
        // No parseable event frames in this synthetic blob queue — degrade is a no-op
        // or frees nothing, but the socket remains open for a later retry.
        _ = outcome
        queue.drain()
        XCTAssertEqual(closed.values(), [])
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

        bus.publishRawForTesting(kind: "e1", payload: .null)
        // both A and B must receive e1 (snapshot includes both after two adds)
        XCTAssertEqual(aReceived, ["e1"], "subscriber A missed event after add; snapshot not rebuilt on subscribe")
        XCTAssertEqual(bReceived, ["e1"], "subscriber B missed event after add; snapshot not rebuilt on subscribe")

        bus.unsubscribe(idA)
        bus.publishRawForTesting(kind: "e2", payload: .null)
        // A must NOT receive e2 (snapshot must have been rebuilt on unsubscribe)
        XCTAssertEqual(aReceived, ["e1"], "removed subscriber A still received event; snapshot not rebuilt on unsubscribe")
        XCTAssertEqual(bReceived, ["e1", "e2"], "subscriber B missed event after A was removed")

        bus.unsubscribe(idB)
        bus.publishRawForTesting(kind: "e3", payload: .null)
        // neither A nor B should receive e3 (empty snapshot)
        XCTAssertEqual(aReceived, ["e1"], "A received event after full unsubscribe")
        XCTAssertEqual(bReceived, ["e1", "e2"], "B received event after full unsubscribe")
    }

    @MainActor
    func test_dispatcher_eventsRecent_returnsBus() async {
        // publish to shared bus then query
        EventBus.shared.publishRawForTesting(kind: "test.kind", payload: .string("hello"))
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "events.recent", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        guard case .array(let evs) = o["events"]! else { return XCTFail() }
        XCTAssertFalse(evs.isEmpty)
    }

    @MainActor
    func test_authenticatedEventsRecentCarriesHostBootAndTreatyIdentity() async throws {
        let baseline = EventBus.shared.currentSeq
        EventBus.shared.publish(
            kind: .workspaceUpdated,
            payload: .object(["workspace_id": .string("workspace-1")])
        )
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let context = MutationRequestContext(
            ownerFingerprint: "owner-1",
            hostId: "host-1",
            bootEpoch: 42
        )
        let response = await dispatcher.dispatchHTTP(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "events.recent",
                params: ["since_seq": .number(Double(baseline))]
            ),
            mutationContext: context
        )

        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["host_id"]?.stringValue, "host-1")
        XCTAssertEqual(result["boot_epoch"]?.intValue, 42)
        let version = try XCTUnwrap(result["treaty_version"]?.objectValue)
        XCTAssertEqual(version["major"]?.intValue, 1)
        XCTAssertEqual(version["minor"]?.intValue, 0)
        let event = try XCTUnwrap(result["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(event["host_id"]?.stringValue, "host-1")
        XCTAssertEqual(event["boot_epoch"]?.intValue, 42)
        XCTAssertEqual(event["kind"]?.stringValue, "workspace.updated")
    }

    // MARK: - PERF-MAC_SOCKET-:110 subscribe(since:) backlog delta slice

    func test_subscribe_sinceNonZero_receivesOnlyDelta() {
        // WHY: a reconnecting client passes its last-seen seq; the server must
        // replay only events AFTER that seq (delta), not the full retained backlog.
        // Delivering the full backlog on every reconnect wastes ~4 MiB of cellular
        // traffic and causes the iOS reducer to double-apply mutations.
        let bus = EventBus()
        bus.publishRawForTesting(kind: "ev.a", payload: .null) // seq 1
        bus.publishRawForTesting(kind: "ev.b", payload: .null) // seq 2
        bus.publishRawForTesting(kind: "ev.c", payload: .null) // seq 3
        bus.publishRawForTesting(kind: "ev.d", payload: .null) // seq 4

        var received: [Int64] = []
        _ = bus.subscribe(since: 3, filter: .full) { received.append($0.seq) }

        XCTAssertEqual(received, [4],
            "subscribe(since:3) must deliver only seq 4 (events with seq > 3) -- " +
            "replaying seqs 1-3 forces the client to re-apply already-applied mutations")
    }

    func test_subscribe_sinceZero_receivesFullBacklog() {
        // WHY: a fresh first-connect client passes since=0 (or server defaults to 0
        // when no header is present); it must receive the complete retained backlog
        // so the mirror starts from the correct initial state.
        let bus = EventBus()
        bus.publishRawForTesting(kind: "ev.a", payload: .null) // seq 1
        bus.publishRawForTesting(kind: "ev.b", payload: .null) // seq 2
        bus.publishRawForTesting(kind: "ev.c", payload: .null) // seq 3

        var received: [Int64] = []
        _ = bus.subscribe(since: 0, filter: .full) { received.append($0.seq) }

        XCTAssertEqual(received, [1, 2, 3],
            "subscribe(since:0) must deliver the full backlog -- " +
            "a fresh client with no prior state needs every event to build its mirror")
    }

    func test_subscribe_sinceAtLastEvent_receivesNoBacklog() {
        // WHY: when the client's last-seen seq equals the bus's highest seq there
        // is no delta; the server must not send any backlog frame (zero bytes saved
        // equals zero bytes wasted on cellular).
        let bus = EventBus()
        bus.publishRawForTesting(kind: "ev.a", payload: .null) // seq 1
        bus.publishRawForTesting(kind: "ev.b", payload: .null) // seq 2

        var received: [Int64] = []
        _ = bus.subscribe(since: 2, filter: .full) { received.append($0.seq) }

        XCTAssertTrue(received.isEmpty,
            "subscribe(since:2) on a bus whose last seq is 2 must deliver no backlog -- " +
            "the client is already fully caught up; any delivery would be a duplicate")

        // live events after subscribe must still arrive
        bus.publishRawForTesting(kind: "ev.c", payload: .null) // seq 3
        XCTAssertEqual(received, [3],
            "live event seq 3 must arrive after an empty backlog -- " +
            "the subscriber must not be silently dropped when its since-seq equals lastSeq")
    }

    func test_persistedReplay_exposesOldestRetainedSequenceAndRequiresBaselineForGap() {
        let bus = EventBus()
        let retained = (1048...1051).map {
            EventBus.Event(seq: Int64($0), kind: "workspace.updated", payload: .null, ts: 0)
        }
        bus.reloadFromPersistence(lastSeq: 1051, recent: retained)

        let replay = bus.recentEvents(since: 1043, maxBytes: nil)

        XCTAssertTrue(replay.requiresBaseline,
                      "a cursor older than the retained range cannot be repaired by partial replay")
        XCTAssertEqual(replay.events.map(\.seq), [1048, 1049, 1050, 1051])
    }

    func test_asyncEventLogLane_doesNotBlockSubscriberDelivery() {
        let bus = EventBus()
        let allowPersistence = DispatchSemaphore(value: 0)
        let persistenceStarted = expectation(description: "persistence started")
        let delivered = expectation(description: "subscriber delivered")
        let publishFinished = expectation(description: "publish finished")
        bus.persister = { _ in
            persistenceStarted.fulfill()
            _ = allowPersistence.wait(timeout: .now() + 1)
        }
        _ = bus.subscribe(since: nil) { _ in delivered.fulfill() }

        DispatchQueue.global().async {
            bus.publish(kind: .workspaceUpdated, payload: .null)
            publishFinished.fulfill()
        }

        wait(for: [persistenceStarted], timeout: 0.5)
        wait(for: [delivered], timeout: 0.1)
        allowPersistence.signal()
        wait(for: [publishFinished], timeout: 0.5)
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
