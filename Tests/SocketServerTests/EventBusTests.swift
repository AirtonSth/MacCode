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
