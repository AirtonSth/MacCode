import XCTest
@testable import SocketServer

/// PERF-114: the POST /v1/rpc handler no longer parks a global-pool worker
/// on a semaphore. It hands the fd to a detached Task whose ONLY dispatch
/// dependency is `dispatchRPC(bodyData:)`. These tests pin the behavior the
/// migrated path now relies on end to end: feed body bytes, await response
/// bytes, assert the JSON-RPC contract. If this seam regressed, every mobile
/// RPC over HTTP would break, so it must be covered without a socket.
final class AsyncRPCDispatchTests: XCTestCase {

    @MainActor
    private func makeServer() -> DirectHTTPServer {
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        // Port/loopback are irrelevant here: we never call start(); we drive
        // the pure async seam directly. We just need a constructed server.
        return DirectHTTPServer(port: UInt16.random(in: 33000...44000),
                                loopbackOnly: true,
                                dispatcher: dispatcher)
    }

    /// WHY: the /v1/rpc Task awaits exactly this method to produce the bytes
    /// it writes back. A valid request must round-trip through the same
    /// dispatcher the socket uses and return a JSON-RPC `result` (no error),
    /// echoing the request id. If this failed, handed-off RPCs would return
    /// wrong/empty bodies even though the socket framing is fine.
    @MainActor
    func test_dispatchRPC_validRequest_returnsResultEchoingId() async throws {
        let server = makeServer()
        let body = """
        {"jsonrpc":"2.0","id":"async-seam","method":"workspace.create","params":{"name":"mobile","cwd":"/tmp"}}
        """.data(using: .utf8)!

        let respData = await server.dispatchRPC(bodyData: body)

        let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj?["id"] as? String, "async-seam",
                       "the async seam must echo the request id the client correlates on")
        let result = obj?["result"] as? [String: Any]
        XCTAssertEqual(result?["name"] as? String, "mobile",
                       "a valid RPC must reach the same dispatcher the socket uses")
        XCTAssertNil(obj?["error"],
                     "a well-formed request must not produce a JSON-RPC error")
    }

    /// WHY: malformed body bytes must yield a well-formed JSON-RPC parseError
    /// (-32700) envelope, never a crash or empty write. The handed-off Task
    /// writes whatever this returns straight to the client, so a non-JSON or
    /// truncated response here would corrupt the wire for that connection.
    @MainActor
    func test_dispatchRPC_malformedBody_returnsParseError() async throws {
        let server = makeServer()
        let respData = await server.dispatchRPC(bodyData: Data("not json".utf8))

        let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
        XCTAssertNotNil(obj, "response must always be valid JSON the client can decode")
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        let error = obj?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32700,
                       "unparseable bytes must map to the JSON-RPC parseError code")
        XCTAssertNil(obj?["result"],
                     "a parse failure must not also carry a result")
    }
}
