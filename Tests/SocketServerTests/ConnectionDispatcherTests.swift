import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import SocketServer

@MainActor
final class ConnectionDispatcherTests: XCTestCase {
    func testOnlyExactActiveUnixCapabilityCanDiscoverAndCallRealFixture() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("connection-ipc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.py")
        try #"""
import json,sys
for line in sys.stdin:
    m=json.loads(line)
    if 'id' not in m: continue
    method=m.get('method')
    if method=='initialize': r={'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
    elif method=='tools/list': r={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
    else: r={'content':[{'type':'text','text':'fixture executed'}],'isError':False}
    print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
"""#.write(to: fixture, atomically: true, encoding: .utf8)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory.path).run()
        let store = ConnectionStore(db: db)
        let connection = AppConnection(name: "IPC fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [fixture.path], access: ConnectionAccess(allRuns: true))
        try store.save(connection)
        let broker = ConnectionBroker(store: store, secrets: EmptyConnectionSecrets())
        let router = ConnectionFixtureRouter(broker: broker)
        let dispatcher = JSONRPCDispatcher(router: router)
        func request(capability: String, thread: AgentThreadID? = nil, run: AgentRunID? = nil, name: String = ConnectionMCPCatalog.call) -> JSONRPCRequest {
            .init(jsonrpc: "2.0", id: .number(1), method: ConnectionMCPCatalog.rpcMethod, params: [
                "thread_id": .string((thread ?? router.thread).value.uuidString), "run_id": .string((run ?? router.run).value.uuidString),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
                "message": .object(["method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(["connection_id": .string(connection.id.uuidString), "name": .string("echo")])])])
            ])
        }
        for req in [request(capability: "wrong"), request(capability: router.capability, thread: AgentThreadID()), request(capability: router.capability, run: AgentRunID())] {
            let denied = await dispatcher.dispatchUnixSocket(req)
            XCTAssertNotNil(denied.error)
        }
        XCTAssertEqual(router.invocations, 0)
        let local = await dispatcher.dispatchLocalIPC(request(capability: router.capability))
        XCTAssertNotNil(local.error)
        let http = await dispatcher.dispatchHTTP(request(capability: router.capability), mutationContext: nil)
        XCTAssertNotNil(http.error)
        let tools = await dispatcher.dispatchUnixSocket(request(capability: router.capability, name: ConnectionMCPCatalog.tools))
        XCTAssertNil(tools.error)
        let result = await dispatcher.dispatchUnixSocket(request(capability: router.capability))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "fixture executed")
        router.active = false
        let revoked = await dispatcher.dispatchUnixSocket(request(capability: router.capability))
        XCTAssertNotNil(revoked.error)
        XCTAssertEqual(router.invocations, 2)
        try await broker.disconnect(connection.id)
    }
}

private struct EmptyConnectionSecrets: ConnectionSecretStore {
    func load(_ id: UUID) throws -> [String: String] { [:] }
    func save(_ values: [String: String], for id: UUID) throws {}
    func delete(_ id: UUID) throws {}
}

@MainActor
private final class ConnectionFixtureRouter: FakeRouter, ConnectionCommandRouting {
    let broker: ConnectionBroker
    let thread = AgentThreadID()
    let run = AgentRunID()
    let capability = "fixture-run-capability"
    var active = true
    var invocations = 0
    init(broker: ConnectionBroker) { self.broker = broker; super.init() }
    override func authenticateManagedHostCall(threadID: AgentThreadID, runID: AgentRunID, delegationCapability: String?, mutation: Bool, method: String) throws {
        guard active, threadID == thread, runID == run, delegationCapability == capability else { throw JSONRPCError(code: -32047, message: "Inactive run") }
    }
    func connectionMCP(message: [String: JSONValue], threadID: AgentThreadID, runID: AgentRunID, capability: String?) async throws -> JSONValue {
        invocations += 1
        let wire = try JSONDecoder().decode([String: ConnectionJSONValue].self, from: JSONEncoder().encode(message))
        let result = try await broker.handle(wire, scope: ConnectionScope(botID: nil, workspaceID: nil, threadID: threadID.value.uuidString), runID: runID.value.uuidString, authorize: { [weak self] in
            try await MainActor.run {
                guard let self else { throw ConnectionError.accessDenied }
                try self.authenticateManagedHostCall(threadID: threadID, runID: runID, delegationCapability: capability, mutation: false, method: ConnectionMCPCatalog.rpcMethod)
            }
        })
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ConnectionJSONValue.object(result)))
    }
}
