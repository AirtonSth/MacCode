import XCTest
import CoreModel
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
        let router = FakeRouter()
        router.workspaces = [Workspace.empty(name: "mobile", cwd: "/tmp")]
        let dispatcher = JSONRPCDispatcher(router: router)
        // Port/loopback are irrelevant here: we never call start(); we drive
        // the pure async seam directly. We just need a constructed server.
        return DirectHTTPServer(port: UInt16.random(in: 33000...44000),
                                loopbackOnly: true,
                                dispatcher: dispatcher,
                                bootEpoch: 1)
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
        {"jsonrpc":"2.0","id":"async-seam","method":"workspace.list","params":{}}
        """.data(using: .utf8)!

        let respData = await server.dispatchRPC(bodyData: body)

        let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj?["id"] as? String, "async-seam",
                       "the async seam must echo the request id the client correlates on")
        let result = obj?["result"] as? [[String: Any]]
        XCTAssertEqual(result?.first?["name"] as? String, "mobile",
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
        XCTAssertTrue(obj?.keys.contains("id") == true)
        XCTAssertTrue(obj?["id"] is NSNull,
                      "JSON-RPC parse failures must preserve the required id key as null")
    }

    @MainActor
    func test_dispatchRPC_structurallyInvalidRequest_returnsInvalidRequestNotParseError() async throws {
        let server = makeServer()
        let bodies = [
            #"{"jsonrpc":"1.0","id":"bad-version","method":"workspace.create","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"workspace.create","params":{}}"#,
            #"{"jsonrpc":"2.0","id":"unknown-key","method":"workspace.create","params":{},"extra":true}"#,
        ]

        for body in bodies {
            let response = await server.dispatchRPC(bodyData: Data(body.utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let error = try XCTUnwrap(object["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32600,
                           "valid JSON with an invalid JSON-RPC shape must return Invalid Request")
        }
    }

    @MainActor
    func test_dispatchRPC_nullID_isPreservedInSuccessfulResponse() async throws {
        let server = makeServer()
        let body = #"{"jsonrpc":"2.0","id":null,"method":"workspace.list","params":{}}"#

        let response = await server.dispatchRPC(bodyData: Data(body.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])

        XCTAssertTrue(object.keys.contains("id"))
        XCTAssertTrue(object["id"] is NSNull,
                      "an explicit null request id must remain explicit for exact response correlation")
        XCTAssertNotNil(object["result"])
    }

    @MainActor
    func test_dispatchRPC_fractionalNumericID_roundTripsExactlyAndBooleanIDIsRejected() async throws {
        let server = makeServer()
        let fractional = await server.dispatchRPC(bodyData: Data(
            #"{"jsonrpc":"2.0","id":1.5,"method":"workspace.list","params":{}}"#.utf8
        ))
        let fractionalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fractional) as? [String: Any]
        )
        XCTAssertEqual((fractionalObject["id"] as? NSNumber)?.doubleValue, 1.5,
                       "finite numeric ids must preserve their exact wire value")
        XCTAssertNotNil(fractionalObject["result"])

        let boolean = await server.dispatchRPC(bodyData: Data(
            #"{"jsonrpc":"2.0","id":true,"method":"workspace.create","params":{}}"#.utf8
        ))
        let booleanObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: boolean) as? [String: Any]
        )
        XCTAssertEqual((booleanObject["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(booleanObject["id"] is NSNull,
                      "boolean ids must fail closed and must not masquerade as numeric ids")
    }

    @MainActor
    func test_dispatchRPC_topLevelBatch_dispatchesEveryItemWithIndependentIDsAndErrors() async throws {
        let server = makeServer()
        let body = #"""
        [
          {"jsonrpc":"2.0","id":"one","method":"workspace.list","params":{}},
          {"jsonrpc":"2.0","id":"bad","method":7,"params":{}},
          {"jsonrpc":"2.0","id":"two","method":"workspace.list","params":{}}
        ]
        """#

        let response = await server.dispatchRPC(bodyData: Data(body.utf8))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        })
        XCTAssertNotNil(byID["one"]?["result"])
        XCTAssertEqual((byID["bad"]?["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertNotNil(byID["two"]?["result"])
    }

    @MainActor
    func test_dispatchRPC_emptyBatch_returnsInvalidRequestObject() async throws {
        let response = await makeServer().dispatchRPC(bodyData: Data("[]".utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(object["id"] is NSNull)
    }

    @MainActor
    func test_dispatchRPC_duplicateBatchIDs_rejectsAmbiguousCorrelation() async throws {
        let body = #"[{"jsonrpc":"2.0","id":1,"method":"system.ping"},{"jsonrpc":"2.0","id":1.0,"method":"system.ping"}]"#
        let response = await makeServer().dispatchRPC(bodyData: Data(body.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(object["id"] is NSNull,
                      "duplicate numeric ids must reject the batch before results become ambiguous")
    }

    @MainActor
    func test_dispatchRPC_adjacentLargeIntegerBatchIDsRemainDistinctAndExact() async throws {
        let body = #"[{"jsonrpc":"2.0","id":9007199254740992,"method":"system.ping"},{"jsonrpc":"2.0","id":9007199254740993,"method":"system.ping"}]"#
        let response = await makeServer().dispatchRPC(bodyData: Data(body.utf8))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [[String: Any]])

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual((items[0]["id"] as? NSNumber)?.stringValue, "9007199254740992")
        XCTAssertEqual((items[1]["id"] as? NSNumber)?.stringValue, "9007199254740993",
                       "adjacent integers above Double's exact range must not collapse to one correlation id")

        let duplicate = #"[{"jsonrpc":"2.0","id":9007199254740993,"method":"system.ping"},{"jsonrpc":"2.0","id":9007199254740993,"method":"system.ping"}]"#
        let duplicateResponse = await makeServer().dispatchRPC(bodyData: Data(duplicate.utf8))
        let duplicateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: duplicateResponse) as? [String: Any]
        )
        XCTAssertEqual((duplicateObject["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(duplicateObject["id"] is NSNull,
                      "an exact repeated large-integer id must still reject the batch")
    }
}
