import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

private final class FixtureConnectionSecrets: ConnectionSecretStore, @unchecked Sendable {
    let lock = NSLock()
    var values: [UUID: [String: String]] = [:]
    func load(_ id: UUID) throws -> [String: String] { lock.lock(); defer { lock.unlock() }; return values[id] ?? [:] }
    func save(_ values: [String: String], for id: UUID) throws { lock.lock(); defer { lock.unlock() }; self.values[id] = values }
    func delete(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}

private final class FixtureRunAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func revoke() { lock.lock(); active = false; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if !active { throw ConnectionError.accessDenied } }
}

final class ConnectionBrokerTests: XCTestCase {
    private let scope = ConnectionScope(botID: "fixture-bot", workspaceID: "fixture-workspace", threadID: "fixture-thread")
    private func fixture() throws -> (URL, ConnectionStore, FixtureConnectionSecrets, ConnectionBroker) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("connection-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory.path).run()
        let store = ConnectionStore(db: db), secrets = FixtureConnectionSecrets()
        try Self.pythonFixture.write(to: directory.appendingPathComponent("mcp.py"), atomically: true, encoding: .utf8)
        return (directory, store, secrets, ConnectionBroker(store: store, secrets: secrets))
    }
    private func message(_ name: String, _ args: [String: ConnectionJSONValue] = [:]) -> [String: ConnectionJSONValue] { ["method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(args)])] }
    private func call(_ broker: ConnectionBroker, _ name: String, _ args: [String: ConnectionJSONValue], authorization: FixtureRunAuthorization = FixtureRunAuthorization()) async throws -> [String: ConnectionJSONValue] {
        try await broker.handle(message(name, args), scope: scope, runID: "fixture-run", authorize: { try authorization.check() })
    }
    func testRealStdioDiscoveryExecutionRestorationAndGrantRevocation() async throws {
        let (directory, store, secrets, broker) = try fixture()
        let connection = AppConnection(name: "Owned stdio fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [directory.appendingPathComponent("mcp.py").path, "stdio"], access: ConnectionAccess(workspaceIDs: ["fixture-workspace"]))
        try await broker.save(connection, credentials: ["FIXTURE_SECRET": "fixture-secret"])
        let count = try await broker.test(connection.id)
        XCTAssertEqual(count, 1)
        let args: [String: ConnectionJSONValue] = ["connection_id": .string(connection.id.uuidString), "name": .string("echo"), "arguments": .object(["value": .string("round trip")])]
        let result = try await call(broker, ConnectionMCPCatalog.call, args)
        XCTAssertEqual(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "round trip")
        let restored = ConnectionBroker(store: ConnectionStore(db: try openDatabase(directory)), secrets: secrets)
        let tools = try await call(restored, ConnectionMCPCatalog.tools, ["connection_id": .string(connection.id.uuidString)])
        XCTAssertEqual(tools["isError"], .bool(false))
        var saved = try XCTUnwrap(store.get(connection.id)); saved.access = ConnectionAccess()
        try store.save(saved)
        do { _ = try await call(broker, ConnectionMCPCatalog.call, args); XCTFail("revoked connection executed") }
        catch { XCTAssertEqual(error as? ConnectionError, .accessDenied) }
        try await broker.disconnect(connection.id)
        try await restored.disconnect(connection.id)
        XCTAssertTrue(try secrets.load(connection.id).isEmpty)
        let metadata = try XCTUnwrap(SettingsRepository(db: try openDatabase(directory)).get(ConnectionStore.storageKey))
        XCTAssertFalse(metadata.contains("fixture-secret"))
    }
    private func openDatabase(_ directory: URL) throws -> SQLiteDB { try Bootstrap(channel: .debug, appSupportOverride: directory.path).run().1 }

    func testRealHTTPAuthenticationSSEAndRunRevocationRejectLateResult() async throws {
        let (directory, store, secrets, broker) = try fixture()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [directory.appendingPathComponent("mcp.py").path, "http", directory.path]
        // SwiftPM/XCTest add loader and Python paths; do not pass those into the owned fixture.
        server.environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "USER", "LANG"].contains($0.key) }
        let diagnostic = directory.appendingPathComponent("http-fixture.log")
        FileManager.default.createFile(atPath: diagnostic.path, contents: nil)
        let diagnosticHandle = try FileHandle(forWritingTo: diagnostic)
        defer { try? diagnosticHandle.close() }
        server.standardOutput = FileHandle.nullDevice; server.standardError = diagnosticHandle
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let portFile = directory.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: portFile.path), server.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard FileManager.default.fileExists(atPath: portFile.path) else {
            let detail = (try? String(contentsOf: diagnostic)) ?? "No fixture diagnostic."
            throw NSError(domain: "OwnedHTTPFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Owned HTTP fixture did not publish its bound port. " + String(detail.prefix(1000))])
        }
        let port = try String(contentsOf: portFile).trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = AppConnection(name: "Owned HTTP fixture", kind: .remoteMCP, endpoint: "http://127.0.0.1:\(port)/sse", access: ConnectionAccess(allRuns: true))
        try await broker.save(connection, credentials: ["Authorization": "Bearer fixture-secret"])
        let discovered = try await broker.test(connection.id)
        XCTAssertEqual(discovered, 1)
        let authorization = FixtureRunAuthorization()
        let task = Task { try await self.call(broker, ConnectionMCPCatalog.call, ["connection_id": .string(connection.id.uuidString), "name": .string("echo"), "arguments": .object(["value": .string("late"), "wait": .bool(true)])], authorization: authorization) }
        let started = directory.appendingPathComponent("started")
        let waitDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: started.path), Date() < waitDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        authorization.revoke()
        do { _ = try await task.value; XCTFail("late result escaped revoked run") }
        catch { XCTAssertEqual(error as? ConnectionError, .accessDenied) }
        // Removing the saved credential causes actual HTTP authentication to fail, never a fake tested state.
        try await broker.disconnect(connection.id)
        var reconnect = try XCTUnwrap(store.get(connection.id)); reconnect.status = .untested; reconnect.endpoint = connection.endpoint
        try await broker.save(reconnect, credentials: [:], expectedRevision: reconnect.revision)
        do { _ = try await broker.test(connection.id); XCTFail("unauthenticated fixture connected") }
        catch { XCTAssertEqual(try store.get(connection.id)?.status, .unavailable) }
        XCTAssertNil(try secrets.load(connection.id)["Authorization"])
        try await broker.disconnect(connection.id)
    }
    func testRemoteEndpointAndCredentialsAreProtectedAcrossMetadataEdits() async throws {
        let (directory, store, secrets, broker) = try fixture()
        let connection = AppConnection(name: "Hosted session", kind: .composio, endpoint: "https://example.com/mcp/private-session?token=private-query", access: ConnectionAccess(allRuns: true))
        try await broker.save(connection, credentials: ["x-api-key": "private-key"])
        var persisted = try XCTUnwrap(store.get(connection.id))
        XCTAssertEqual(persisted.endpoint, "https://example.com/protected-mcp-endpoint")
        persisted.account = "Work"
        try await broker.save(persisted, credentials: nil, expectedRevision: persisted.revision)
        XCTAssertTrue(try secrets.load(connection.id).values.contains(connection.endpoint))
        let raw = try XCTUnwrap(SettingsRepository(db: try openDatabase(directory)).get(ConnectionStore.storageKey))
        for secret in ["private-session", "private-query", "private-key"] { XCTAssertFalse(raw.contains(secret)) }
        try await broker.disconnect(connection.id)
        XCTAssertTrue(try secrets.load(connection.id).isEmpty)
    }
    func testDisconnectCannotDeleteCredentialsSavedWhileOldClientCloses() async throws {
        let (directory, store, secrets, _) = try fixture()
        let gate = ConnectionCloseGate()
        defer { Task { await gate.release() } }
        let broker = ConnectionBroker(store: store, secrets: secrets, beforeClientCloseForTesting: { await gate.pause() })
        let connection = AppConnection(name: "Close race fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [directory.appendingPathComponent("mcp.py").path, "stdio"], access: ConnectionAccess(allRuns: true))
        try await broker.save(connection, credentials: ["FIXTURE_SECRET": "fixture-secret"])
        _ = try await broker.test(connection.id)
        let disconnect = Task { try await broker.disconnect(connection.id) }
        await gate.waitForEntry()
        let disconnected = try XCTUnwrap(store.get(connection.id))
        XCTAssertEqual(disconnected.status, .disconnected)
        try await broker.save(disconnected, credentials: ["FIXTURE_SECRET": "replacement-secret"], expectedRevision: disconnected.revision)
        await gate.release()
        try await disconnect.value
        XCTAssertEqual(try secrets.load(connection.id)["FIXTURE_SECRET"], "replacement-secret")
        XCTAssertEqual(try store.get(connection.id)?.status, .untested)
        try await broker.disconnect(connection.id)
    }
    func testDisconnectedRemoteRequiresFullEndpointReentry() async throws {
        let (_, store, _, broker) = try fixture()
        let connection = AppConnection(name: "Protected remote", kind: .remoteMCP, endpoint: "https://example.com/private-session")
        try await broker.save(connection, credentials: [:])
        try await broker.disconnect(connection.id)
        let disconnected = try XCTUnwrap(store.get(connection.id))
        do { try await broker.save(disconnected, credentials: [:], expectedRevision: disconnected.revision); XCTFail("sanitized endpoint reused as actual server") }
        catch { XCTAssertEqual(error as? ConnectionError, .endpointRequired) }
        XCTAssertEqual(try store.get(connection.id)?.status, .disconnected)
    }
    func testMalformedServerReplyIsUnavailableAndFacadeRedactsErrors() async throws {
        let (directory, store, _, broker) = try fixture()
        let bad = AppConnection(name: "Malformed fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [directory.appendingPathComponent("mcp.py").path, "bad"], access: ConnectionAccess(allRuns: true))
        try await broker.save(bad, credentials: nil)
        do { _ = try await broker.test(bad.id); XCTFail("malformed server passed") }
        catch { XCTAssertEqual(try store.get(bad.id)?.status, .unavailable) }
        let facade = ManagedConnectionsMCP(invoke: { _ in throw NSError(domain: "secret-token", code: 1) })
        let response = try XCTUnwrap(facade.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"connection_list"}}"#))
        XCTAssertFalse(response.contains("secret-token")); XCTAssertTrue(response.contains("isError"))
        try await broker.disconnect(bad.id)
    }
    func testAgentDiscoveryRecoversAfterInitializationFailureWithoutConfigurationChangeOrWriteRetry() async throws {
        let (directory, store, _, broker) = try fixture()
        let script = directory.appendingPathComponent("recover.py")
        try #"""
import json,sys,os
root=sys.argv[1]
for line in sys.stdin:
    m=json.loads(line)
    if 'id' not in m: continue
    method=m.get('method')
    if method=='initialize':
        with open(os.path.join(root,'initializations'),'a') as f: f.write('initialize\n')
        if not os.path.exists(os.path.join(root,'ready')):
            print(json.dumps({'jsonrpc':'2.0','id':m['id'],'error':{'code':-32000,'message':'owned transient initialization failure'}}),flush=True)
            continue
        r={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'recovery-fixture','version':'1'}}
    elif method=='tools/list': r={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
    elif method=='tools/call':
        with open(os.path.join(root,'executions'),'a') as f: f.write('execute\n')
        r={'content':[{'type':'text','text':'explicit execution'}],'isError':False}
    else: continue
    print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
"""#.write(to: script, atomically: true, encoding: .utf8)
        let connection = AppConnection(name: "Recovering fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [script.path, directory.path], access: ConnectionAccess(allRuns: true))
        try await broker.save(connection, credentials: nil)
        let arguments: [String: ConnectionJSONValue] = ["connection_id": .string(connection.id.uuidString)]
        do { _ = try await call(broker, ConnectionMCPCatalog.tools, arguments); XCTFail("initialization should fail once") }
        catch { XCTAssertEqual(error as? ConnectionError, .invalidResponse) }
        let revision = try XCTUnwrap(store.get(connection.id)).revision
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("executions").path))
        try Data().write(to: directory.appendingPathComponent("ready"))
        let recovered = try await call(broker, ConnectionMCPCatalog.tools, arguments)
        XCTAssertEqual(recovered["isError"], .bool(false))
        XCTAssertEqual(try store.get(connection.id)?.revision, revision, "recovery must not depend on a settings edit or native test bump")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("initializations")).split(separator: "\n").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("executions").path), "discovery recovery must never execute a service action")
        _ = try await call(broker, ConnectionMCPCatalog.call, ["connection_id": .string(connection.id.uuidString), "name": .string("echo")])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("executions")).split(separator: "\n").count, 1, "only the explicit tool call executes, exactly once")
        try await broker.disconnect(connection.id)
    }
    func testPagedDiscoveryCallsToolFoundOnlyOnSecondPage() async throws {
        let (directory, _, _, broker) = try fixture()
        let connection = AppConnection(name: "Paged fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [directory.appendingPathComponent("mcp.py").path, "pages", directory.path], access: ConnectionAccess(allRuns: true))
        try await broker.save(connection, credentials: nil)
        let count = try await broker.test(connection.id)
        XCTAssertEqual(count, 2)
        let result = try await call(broker, ConnectionMCPCatalog.call, ["connection_id": .string(connection.id.uuidString), "name": .string("second_page"), "arguments": .object(["value": .string("page two reached")])])
        XCTAssertEqual(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "page two reached")
        try await broker.disconnect(connection.id)
    }
    func testUnboundedDiscoveryStopsAt64PagesAndUnsupportedVersionFailsClosed() async throws {
        for mode in ["endless", "unsupported"] {
            let (directory, store, _, broker) = try fixture()
            let connection = AppConnection(name: "Bounded fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [directory.appendingPathComponent("mcp.py").path, mode, directory.path], access: ConnectionAccess(allRuns: true))
            try await broker.save(connection, credentials: nil)
            do { _ = try await broker.test(connection.id); XCTFail("incompatible fixture reported tested") }
            catch { XCTAssertEqual(error as? ConnectionError, .invalidResponse) }
            XCTAssertEqual(try store.get(connection.id)?.status, .unavailable)
            let pageLog = directory.appendingPathComponent("pages")
            if mode == "endless" { XCTAssertEqual(try String(contentsOf: pageLog).split(separator: "\n").count, 64) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: pageLog.path)) }
            try await broker.disconnect(connection.id)
        }
    }
    private static let pythonFixture = #"""
import sys, json, os, time
mode=sys.argv[1]
def respond(m):
    method=m.get('method')
    if method=='initialize': r={'protocolVersion':('unsupported-version' if mode=='unsupported' else '2025-06-18' if mode=='http' else '2024-11-05'),'capabilities':{'tools':{}},'serverInfo':{'name':'owned-fixture','version':'1'}}
    elif method=='tools/list': r={'tools':[{'name':'echo','description':'Owned safe fixture','inputSchema':{'type':'object','properties':{'value':{'type':'string'}}}}]}
    elif method=='tools/call':
        a=m.get('params',{}).get('arguments',{})
        if a.get('wait'):
            open(os.path.join(sys.argv[2],'started'),'w').close()
            time.sleep(.5)
        r={'content':[{'type':'text','text':a.get('value','')}],'isError':False}
    else: return None
    if mode in ('pages','endless') and method=='tools/list':
        with open(os.path.join(sys.argv[2],'pages'),'a') as f: f.write('page\n')
        cursor=m.get('params',{}).get('cursor')
        if mode=='endless': r={'tools':[],'nextCursor':str(int(cursor or '0')+1)}
        elif cursor is None: r={'tools':[{'name':'first_page','inputSchema':{'type':'object'}}],'nextCursor':'page-two'}
        elif cursor=='page-two': r={'tools':[{'name':'second_page','inputSchema':{'type':'object'}}]}
        else: return None
    if mode=='bad' and method=='tools/list': r={'unexpected':'no tools'}
    return {'jsonrpc':'2.0','id':m.get('id'),'result':r}
if mode in ('stdio','bad','pages','endless','unsupported'):
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        if mode=='stdio' and os.environ.get('FIXTURE_SECRET')!='fixture-secret': sys.exit(3)
        print(json.dumps(respond(m)),flush=True)
else:
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from socketserver import TCPServer
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args): pass
        def do_POST(self):
            if self.headers.get('Authorization')!='Bearer fixture-secret':
                self.send_response(401); self.end_headers(); return
            m=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            expected=None if m.get('method')=='initialize' else '2025-06-18'
            if self.headers.get('MCP-Protocol-Version')!=expected:
                self.send_response(400); self.send_header('Content-Length','0'); self.end_headers(); return
            if 'id' not in m:
                self.send_response(202); self.send_header('Content-Length','0'); self.end_headers(); return
            reply=json.dumps(respond(m))
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Mcp-Session-Id','fixture-session'); self.end_headers()
            self.wfile.write(('data: '+reply+'\n\n').encode()); self.wfile.flush()
            time.sleep(10) # Keep SSE open: the client must return on the event, not wait for EOF.
    class OwnedHTTPServer(ThreadingHTTPServer):
        def server_bind(self):
            # HTTPServer's default bind performs a blocking reverse-DNS lookup.
            # This fixture only accepts numeric loopback and never needs DNS.
            TCPServer.server_bind(self)
            self.server_name='localhost'
            self.server_port=self.server_address[1]
    server=OwnedHTTPServer(('127.0.0.1',0),Handler)
    with open(os.path.join(sys.argv[2],'port'),'w') as f: f.write(str(server.server_port))
    server.serve_forever()
"""#
}

private actor ConnectionCloseGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { closeWaiter = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { released = true; closeWaiter?.resume(); closeWaiter = nil }
}
