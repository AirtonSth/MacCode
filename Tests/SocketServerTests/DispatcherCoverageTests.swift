import XCTest
@testable import SocketServer
import CoreModel

@MainActor
final class DispatcherCoverageTests: XCTestCase {
    func test_window_create_routes_through_router() async {
        let r = FakeRouter()
        let d = JSONRPCDispatcher(router: r)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "window.create", params: ["title": .string("alt")]))
        XCTAssertNil(resp.error)
    }

    func test_pane_swap_returns_true() async {
        let r = FakeRouter()
        let d = JSONRPCDispatcher(router: r)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "pane.swap", params: [
            "workspace_id": .string(UUID().uuidString),
            "a": .string(UUID().uuidString),
            "b": .string(UUID().uuidString)
        ]))
        XCTAssertEqual(resp.result, .bool(true))
    }

    func test_notification_create_returns_id() async {
        let r = FakeRouter()
        let d = JSONRPCDispatcher(router: r)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "notification.create", params: [
            "title": .string("hello")
        ]))
        XCTAssertNil(resp.error)
        if case .object(let o) = resp.result!, case .string = o["id"]! {} else { XCTFail() }
    }

    func test_browser_action_sentinels_route_through_router() async {
        let r = FakeRouter()
        let d = JSONRPCDispatcher(router: r)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "browser.click", params: [
            "id": .string(UUID().uuidString),
            "ref": .string("rc2-1")
        ]))
        XCTAssertNil(resp.error)
        XCTAssertNotNil(resp.result)
    }
}
