import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime
@testable import SocketServer
@testable import AppShell

/// Real host receipt/grant composition. Only the model runner and secret storage are replaced;
/// the provider-neutral facade, AppCommandRouter and stdio service execution are production code.
@MainActor
final class AppConnectionsRouterTests: XCTestCase {
    func testProductionRouterExecutesOnlyForExactLiveReceiptAndCurrentWorkspaceGrant() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let admitted = try h.receipt(workspace: h.workspace)
        let other = try h.receipt(workspace: h.otherWorkspace)
        let dispatcher = JSONRPCDispatcher(router: h.router)
        func request(_ identity: Harness.Identity, capability: String? = nil, run: AgentRunID? = nil, name: String = ConnectionMCPCatalog.call, wait: Bool = false) -> JSONRPCRequest {
            .init(jsonrpc: "2.0", id: .number(1), method: ConnectionMCPCatalog.rpcMethod, params: [
                "thread_id": .string(identity.thread.id.value.uuidString), "run_id": .string((run ?? identity.run).value.uuidString),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability ?? identity.capability),
                "message": .object(h.message(name: name, wait: wait))
            ])
        }
        for deniedRequest in [request(admitted, capability: "wrong-capability"), request(admitted, run: AgentRunID()), request(other)] {
            let denied = await dispatcher.dispatchUnixSocket(deniedRequest)
            XCTAssertNotNil(denied.error)
        }
        var missingParams = request(admitted).params ?? [:]
        missingParams.removeValue(forKey: BotPeerDelegation.capabilityRPCParameterKey)
        let missing = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(2), method: ConnectionMCPCatalog.rpcMethod, params: missingParams))
        XCTAssertNotNil(missing.error)
        XCTAssertEqual(h.callCount, 0)
        let tools = await dispatcher.dispatchUnixSocket(request(admitted, name: ConnectionMCPCatalog.tools))
        XCTAssertNil(tools.error)
        let valid = await dispatcher.dispatchUnixSocket(request(admitted))
        XCTAssertNil(valid.error)
        XCTAssertEqual(valid.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "production fixture executed")
        XCTAssertEqual(h.callCount, 1)
        var connection = try XCTUnwrap(h.store.get(h.connection.id))
        connection.access = ConnectionAccess()
        try h.store.save(connection)
        let revokedGrant = await dispatcher.dispatchUnixSocket(request(admitted))
        XCTAssertNotNil(revokedGrant.error)
        XCTAssertEqual(h.callCount, 1)
        connection = try XCTUnwrap(h.store.get(h.connection.id))
        connection.access = h.connection.access
        try h.store.save(connection)
        // A call already accepted by the service must not return data after its real host receipt ends.
        let pending = Task { await dispatcher.dispatchUnixSocket(request(admitted, wait: true)) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: h.root.appendingPathComponent("started").path), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("started").path))
        try h.context.orchestrationRuntime.finalizeReceipt(runId: admitted.run, status: .completed)
        let late = await pending.value
        XCTAssertNotNil(late.error)
        let ended = await dispatcher.dispatchUnixSocket(request(admitted))
        XCTAssertNotNil(ended.error)
        XCTAssertEqual(h.callCount, 2, "only the two previously admitted calls reached the owned service")
        try h.context.orchestrationRuntime.finalizeReceipt(runId: other.run, status: .completed)
        try await h.context.connectionBroker.disconnect(h.connection.id)
    }

    func testNonBotOwnerRunsReceiveLiveAuthorityAndExecuteSameConnectionAcrossAllProviders() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        for provider in [AgentProvider.claude, .codex, .grok, .distill] {
            let thread = AgentThread(workspaceId: h.workspace.id, title: "Owner \(provider.rawValue)", provider: provider, model: "fixture", permissionMode: .fullAccess)
            try h.context.threadRepo.upsert(thread)
            let runner = ConnectionCapturingRunner(provider: provider)
            let coordinator = AgentRunCoordinator(runRepo: h.context.runRepo, messageRepo: h.context.messageRepo, threadRepo: h.context.threadRepo, orchestrationRuntime: h.context.orchestrationRuntime, providers: [provider: runner], botSecretStore: InMemoryBotSecretStore())
            // The actual AppContext closure supplies host-owned socket/thread attribution.
            coordinator.runEnvironmentProvider = h.context.coordinator.runEnvironmentProvider
            let run = AgentRunID()
            _ = try await coordinator.startRun(AgentRunRequest(runId: run, threadId: thread.id, provider: provider, model: "fixture", cwd: h.root.path, prompt: "Owned fixture only", permissionMode: .fullAccess))
            defer { coordinator.stopRun(run) }
            let env = runner.environment
            XCTAssertNil(env[BotSelfConfigCatalog.callerEnvironmentKey], "this proves ordinary workspace execution, without a Bot identity")
            XCTAssertEqual(env[BotPeerDelegation.threadEnvironmentKey], thread.id.value.uuidString)
            XCTAssertEqual(env[BotPeerDelegation.runEnvironmentKey]?.lowercased(), run.value.uuidString.lowercased())
            XCTAssertFalse((env[BotPeerDelegation.socketEnvironmentKey] ?? "").isEmpty)
            let capability = try XCTUnwrap(env[BotPeerDelegation.capabilityEnvironmentKey])
            XCTAssertTrue(AgentDelegationCapabilityTransport.isWellFormed(capability))
            XCTAssertNotNil(try h.context.orchestrationRuntime.activeReceipt(runId: run, threadId: thread.id, delegationCapability: capability))
            let result = try await h.router.connectionMCP(message: h.message(), threadID: thread.id, runID: run, capability: capability)
            XCTAssertEqual(result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "production fixture executed", provider.rawValue)
        }
        XCTAssertEqual(h.callCount, 4)
        try await h.context.connectionBroker.disconnect(h.connection.id)
    }

    func testSupervisedProductionReceiptCanDiscoverButCannotExecuteServiceTools() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let identity = try h.receipt(workspace: h.workspace, permission: .supervised)
        let dispatcher = JSONRPCDispatcher(router: h.router)
        func request(_ name: String) -> JSONRPCRequest {
            .init(jsonrpc: "2.0", id: .number(1), method: ConnectionMCPCatalog.rpcMethod, params: [
                "thread_id": .string(identity.thread.id.value.uuidString), "run_id": .string(identity.run.value.uuidString),
                BotPeerDelegation.capabilityRPCParameterKey: .string(identity.capability), "message": .object(h.message(name: name))
            ])
        }
        for name in [ConnectionMCPCatalog.list, ConnectionMCPCatalog.tools] {
            let discovered = await dispatcher.dispatchUnixSocket(request(name))
            XCTAssertNil(discovered.error)
        }
        let denied = await dispatcher.dispatchUnixSocket(request(ConnectionMCPCatalog.call))
        XCTAssertEqual(denied.error?.code, -32048)
        XCTAssertEqual(denied.error?.message, ConnectionError.supervised.description)
        XCTAssertEqual(h.callCount, 0, "the real configured service must not receive tools/call from a supervised run")
        try h.context.orchestrationRuntime.finalizeReceipt(runId: identity.run, status: .completed)
        try await h.context.connectionBroker.disconnect(h.connection.id)
    }

    func testActorOnlyBotGrantWorksAndConflictingConversationIdentityFailsClosed() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let actorBot = try h.context.botStore.create(name: "Actor fixture", title: "", description: "", workspaceID: h.workspace.id)
        let otherBot = try h.context.botStore.create(name: "Other fixture", title: "", description: "", workspaceID: h.workspace.id)
        let identity = try h.receipt(workspace: h.workspace, actor: .bot(actorBot.id))
        XCTAssertNil(try h.context.botStore.conversationLinked(to: identity.thread.id))
        var connection = try XCTUnwrap(h.store.get(h.connection.id))
        connection.access = ConnectionAccess(botIDs: [actorBot.id.value.uuidString])
        try h.store.save(connection)
        let result = try await h.router.connectionMCP(message: h.message(), threadID: identity.thread.id, runID: identity.run, capability: identity.capability)
        XCTAssertEqual(result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "production fixture executed")
        XCTAssertEqual(h.callCount, 1)
        try h.context.botStore.upsertConversation(BotConversation(botID: otherBot.id, title: "Inconsistent legacy link", linkedAgentThreadID: identity.thread.id))
        do {
            _ = try await h.router.connectionMCP(message: h.message(), threadID: identity.thread.id, runID: identity.run, capability: identity.capability)
            XCTFail("a conversation and actor from different Bots must not authorize each other")
        } catch { XCTAssertEqual(error as? ConnectionError, .accessDenied) }
        XCTAssertEqual(h.callCount, 1)
        try h.context.orchestrationRuntime.finalizeReceipt(runId: identity.run, status: .completed)
        try await h.context.connectionBroker.disconnect(h.connection.id)
    }

    @MainActor
    private struct Harness {
        struct Identity { let thread: AgentThread; let run: AgentRunID; let capability: String }
        let root: URL
        let context: AppContext
        let router: AppCommandRouter
        let store: ConnectionStore
        let workspace: Workspace
        let otherWorkspace: Workspace
        let connection: AppConnection
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("app-connections-" + UUID().uuidString, isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let first = root.appendingPathComponent("first", isDirectory: true)
            let second = root.appendingPathComponent("second", isDirectory: true)
            for directory in [home, first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path, agentSkillsHomeOverrideForTesting: home, contextualSecretStore: InMemoryBotSecretStore())
            router = AppCommandRouter(context: context, sshPasswordStore: KeychainSSHPasswordStore(), secretStore: InMemoryBotSecretStore())
            context.router = router
            workspace = try router.createWorkspace(name: "Allowed", cwd: first.path)
            otherWorkspace = try router.createWorkspace(name: "Other", cwd: second.path)
            store = ConnectionStore(db: context.db)
            // No Keychain read or write: the only credential seam returns an empty fixture environment.
            context.connectionBroker = ConnectionBroker(store: store, secrets: NoConnectionFixtureSecrets())
            let script = root.appendingPathComponent("mcp.py")
            try Self.script.write(to: script, atomically: true, encoding: .utf8)
            connection = AppConnection(name: "Production route fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: [script.path, root.path], access: ConnectionAccess(workspaceIDs: [workspace.id.value.uuidString]))
            try store.save(connection)
        }
        func receipt(workspace: Workspace, permission: AgentPermissionMode = .fullAccess, actor: RunActor = .none) throws -> Identity {
            let thread = AgentThread(workspaceId: workspace.id, title: "Fixture owner", provider: .distill, model: "fixture", permissionMode: permission, actor: actor)
            try context.threadRepo.upsert(thread)
            let run = AgentRunID(), capability = AgentDelegationCapability.issue()
            _ = try context.orchestrationRuntime.recordExternalRoot(runId: run, threadId: thread.id, provider: .distill, providerInstanceId: "distill", model: "fixture", permissionMode: permission, delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(capability))
            return Identity(thread: thread, run: run, capability: capability)
        }
        func message(name: String = ConnectionMCPCatalog.call, wait: Bool = false) -> [String: JSONValue] {
            ["method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(["connection_id": .string(connection.id.uuidString), "name": .string("echo"), "arguments": .object(["wait": .bool(wait)])])])]
        }
        var callCount: Int { ((try? String(contentsOf: root.appendingPathComponent("calls"))) ?? "").split(separator: "\n").count }
        private static let script = #"""
import json,sys,os,time
root=sys.argv[1]
for line in sys.stdin:
    m=json.loads(line)
    if 'id' not in m: continue
    method=m.get('method')
    if method=='initialize': r={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'owned-fixture','version':'1'}}
    elif method=='tools/list': r={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
    elif method=='tools/call':
        with open(os.path.join(root,'calls'),'a') as f: f.write('call\n')
        if m.get('params',{}).get('arguments',{}).get('wait'):
            open(os.path.join(root,'started'),'w').close()
            time.sleep(.5)
        r={'content':[{'type':'text','text':'production fixture executed'}],'isError':False}
    else: continue
    print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
"""#
    }
}

private struct NoConnectionFixtureSecrets: ConnectionSecretStore {
    func load(_ id: UUID) throws -> [String: String] { [:] }
    func save(_ values: [String: String], for id: UUID) throws {}
    func delete(_ id: UUID) throws {}
}

private final class ConnectionCapturingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var captured: [String: String] = [:]
    init(provider: AgentProvider) { self.provider = provider }
    var environment: [String: String] { lock.lock(); defer { lock.unlock() }; return captured }
    func listModels() async -> [AgentModelDescriptor] { [.init(id: "fixture", label: "Owned fixture", provider: provider, supportsReasoning: false)] }
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock(); captured = request.environment; lock.unlock()
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) { onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil)) }
    }
}
