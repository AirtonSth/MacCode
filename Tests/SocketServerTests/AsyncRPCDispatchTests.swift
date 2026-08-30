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
    func test_dispatchRPC_topLevelBatch_rejectsMalformedSiblingBeforeAnyItem() async throws {
        let server = makeServer()
        let body = #"""
        [
          {"jsonrpc":"2.0","id":"one","method":"workspace.list","params":{}},
          {"jsonrpc":"2.0","id":"bad","method":7,"params":{}},
          {"jsonrpc":"2.0","id":"two","method":"workspace.list","params":{}}
        ]
        """#

        let response = await server.dispatchRPC(bodyData: Data(body.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(object["id"] is NSNull)
    }

    @MainActor
    func test_dispatchRPC_topLevelReadOnlyBatch_preservesOrderedIndependentResults() async throws {
        let server = makeServer()
        let body = #"""
        [
          {"jsonrpc":"2.0","id":"one","method":"workspace.list","params":{}},
          {"jsonrpc":"2.0","id":"two","method":"system.ping","params":{}}
        ]
        """#

        let response = await server.dispatchRPC(bodyData: Data(body.utf8))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String }, ["one", "two"])
        XCTAssertTrue(items.allSatisfy { $0["result"] != nil })
    }

    @MainActor
    func test_dispatchRPC_persistedCapabilitiesGateSingleMethods() async throws {
        let server = makeServer()
        let readPrincipal = DirectRPCPrincipal(
            ownerFingerprint: "read-owner",
            grantedCapabilities: "read"
        )

        let read = await server.dispatchRPC(
            bodyData: Data(#"{"jsonrpc":"2.0","id":"read","method":"workspace.list","params":{}}"#.utf8),
            principal: readPrincipal
        )
        let readObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: read) as? [String: Any]
        )
        XCTAssertNotNil(readObject["result"])

        let receipt = await server.dispatchRPC(
            bodyData: Data(#"{"jsonrpc":"2.0","id":"receipt","method":"command.receipt.status","params":{"method":"workspace.create","client_request_id":"00000000-0000-0000-0000-000000000001"}}"#.utf8),
            principal: readPrincipal
        )
        let receiptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: receipt) as? [String: Any]
        )
        XCTAssertNotEqual(
            (receiptObject["error"] as? [String: Any])?["code"] as? Int,
            -32003,
            "command.receipt.status must be classified as an authorized read"
        )

        let denied = await server.dispatchRPC(
            bodyData: Data(#"{"jsonrpc":"2.0","id":"write","method":"workspace.create","params":{"name":"forbidden"}}"#.utf8),
            principal: readPrincipal
        )
        let deniedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: denied) as? [String: Any]
        )
        XCTAssertEqual(
            (deniedObject["error"] as? [String: Any])?["code"] as? Int,
            -32003
        )

        let filePrincipal = DirectRPCPrincipal(
            ownerFingerprint: "file-owner",
            grantedCapabilities: "file"
        )
        let fileAllowed = await server.dispatchRPC(
            bodyData: Data(#"{"jsonrpc":"2.0","id":"file","method":"fs.roots","params":{}}"#.utf8),
            principal: filePrincipal
        )
        let fileAllowedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fileAllowed) as? [String: Any]
        )
        XCTAssertNotEqual(
            (fileAllowedObject["error"] as? [String: Any])?["code"] as? Int,
            -32003,
            "file scope must reach file RPC dispatch"
        )
        let fileDeniedRead = await server.dispatchRPC(
            bodyData: Data(#"{"jsonrpc":"2.0","id":"file-read","method":"workspace.list","params":{}}"#.utf8),
            principal: filePrincipal
        )
        let fileDeniedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fileDeniedRead) as? [String: Any]
        )
        XCTAssertEqual(
            (fileDeniedObject["error"] as? [String: Any])?["code"] as? Int,
            -32003
        )

        let nestedFileBatch = Data(#"{"jsonrpc":"2.0","id":"nested","method":"rpc.batch","params":{"calls":[{"method":"fs.roots","params":{}}]}}"#.utf8)
        let nestedDenied = await server.dispatchRPC(
            bodyData: nestedFileBatch,
            principal: readPrincipal
        )
        let nestedDeniedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nestedDenied) as? [String: Any]
        )
        XCTAssertEqual(
            (nestedDeniedObject["error"] as? [String: Any])?["code"] as? Int,
            -32003,
            "rpc.batch must not let read scope tunnel into file methods"
        )
        let nestedAllowed = await server.dispatchRPC(
            bodyData: nestedFileBatch,
            principal: filePrincipal
        )
        let nestedAllowedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nestedAllowed) as? [String: Any]
        )
        XCTAssertNotEqual(
            (nestedAllowedObject["error"] as? [String: Any])?["code"] as? Int,
            -32003,
            "file scope must retain access to batched file reads"
        )

        XCTAssertTrue(JSONRPCDispatcher.isAuthorized(
            method: "fs.workspace.read",
            grantedCapabilities: "file"
        ))
        for method in ["sync.snapshot", "sync.snapshot.begin", "sync.snapshot.chunk", "sync.snapshot.commit"] {
            XCTAssertTrue(JSONRPCDispatcher.isAuthorized(
                method: method,
                grantedCapabilities: "read"
            ), "\(method) must remain readable for baseline recovery")
        }

        let snapshot = await server.dispatchRPC(
            bodyData: Data(#"{"jsonrpc":"2.0","id":"snapshot","method":"sync.snapshot","params":{}}"#.utf8),
            principal: readPrincipal
        )
        let snapshotObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot) as? [String: Any]
        )
        XCTAssertNotEqual(
            (snapshotObject["error"] as? [String: Any])?["code"] as? Int,
            -32003,
            "sync.snapshot must pass read capability admission"
        )
    }

    @MainActor
    func test_dispatchRPC_starPrincipalPreservesSingleMutationAccess() async throws {
        let router = FakeRouter()
        let server = DirectHTTPServer(
            port: UInt16.random(in: 33_000...44_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            bootEpoch: 1
        )
        let requestID = UUID().uuidString
        let body = #"{"jsonrpc":"2.0","id":"write","method":"workspace.create","params":{"name":"allowed","cwd":"/tmp","client_request_id":"\#(requestID)"}}"#
        let principal = DirectRPCPrincipal(
            ownerFingerprint: "full-owner",
            grantedCapabilities: "*"
        )

        let response = await server.dispatchRPC(
            bodyData: Data(body.utf8),
            principal: principal
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertNotEqual(
            (object["error"] as? [String: Any])?["code"] as? Int,
            -32003,
            "full-access principal must pass capability admission"
        )
        // FakeRouter intentionally has no durable command-receipt repository,
        // so dispatch then fails closed before the mutation for that unrelated
        // reason. Reaching that domain error proves the capability gate admitted
        // `*`; production mutation/receipt behavior is covered elsewhere.
        XCTAssertEqual(
            (object["error"] as? [String: Any])?["code"] as? Int,
            -32091
        )
        XCTAssertTrue(router.workspaces.isEmpty)
    }

    @MainActor
    func test_dispatchRPC_topLevelMutationBatchRejectsBeforeAnyEffect() async throws {
        let router = FakeRouter()
        let server = DirectHTTPServer(
            port: UInt16.random(in: 33_000...44_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            bootEpoch: 1
        )
        let requestID = UUID().uuidString
        let body = #"""
        [
          {"jsonrpc":"2.0","id":"mutate","method":"workspace.create","params":{"name":"must-not-exist","cwd":"/tmp","client_request_id":"\#(requestID)"}},
          {"jsonrpc":"2.0","id":"read","method":"workspace.list","params":{}}
        ]
        """#

        let response = await server.dispatchRPC(bodyData: Data(body.utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertTrue(router.workspaces.isEmpty,
                      "batch preflight must reject before its first mutation executes")
    }

    @MainActor
    func test_dispatchRPC_unauthorizedBatchSiblingRejectsBeforeAnyEffect() async throws {
        let router = FakeRouter()
        let server = DirectHTTPServer(
            port: UInt16.random(in: 33_000...44_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            bootEpoch: 1
        )
        let body = #"""
        [
          {"jsonrpc":"2.0","id":"read","method":"workspace.list","params":{}},
          {"jsonrpc":"2.0","id":"write","method":"workspace.create","params":{"name":"must-not-exist"}}
        ]
        """#
        let principal = DirectRPCPrincipal(
            ownerFingerprint: "read-owner",
            grantedCapabilities: "read"
        )

        let response = await server.dispatchRPC(
            bodyData: Data(body.utf8),
            principal: principal
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32003)
        XCTAssertTrue(router.workspaces.isEmpty)
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
