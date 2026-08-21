import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import SocketServer

@MainActor
final class RemoteCodeHostCatalogDispatcherTests: XCTestCase {
    func test_unixHostMutationsReplayMismatchAndUnknownOutcome() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        func request(
            name: String,
            operationID: String,
            extra: [String: JSONValue] = [:]
        ) -> JSONRPCRequest {
            var params: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
                "client_request_id": .string(operationID),
                "name": .string(name),
            ]
            for (key, value) in extra { params[key] = value }
            return JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: RemoteCodeHostCatalog.botCreateRPC,
                params: params
            )
        }

        let first = await dispatcher.dispatchUnixSocket(request(name: "Oliver", operationID: "op-1"))
        XCTAssertNil(first.error)
        XCTAssertEqual(first.result?.objectValue?["name"]?.stringValue, "Oliver")
        XCTAssertEqual(router.createCount, 1)

        let replay = await dispatcher.dispatchUnixSocket(request(name: "Oliver", operationID: "op-1"))
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.result?.objectValue?["id"]?.stringValue, first.result?.objectValue?["id"]?.stringValue)
        XCTAssertEqual(router.createCount, 1, "same operation_id must not create a second Bot")

        let mismatch = await dispatcher.dispatchUnixSocket(request(name: "Nora", operationID: "op-1"))
        XCTAssertEqual(mismatch.error?.code, -32093)
        XCTAssertEqual(mismatch.error?.data?.objectValue?["reason"]?.stringValue, "idempotencyRequestMismatch")
        XCTAssertEqual(router.createCount, 1)

        router.markNextUnknown = true
        let lost = await dispatcher.dispatchUnixSocket(request(name: "Piper", operationID: "op-2"))
        XCTAssertEqual(lost.error?.code, -32095)
        XCTAssertEqual(lost.error?.data?.objectValue?["requiresSnapshot"]?.boolValue, true)
        let retryLost = await dispatcher.dispatchUnixSocket(request(name: "Piper", operationID: "op-2"))
        XCTAssertEqual(retryLost.error?.code, -32095)
        XCTAssertEqual(router.createCount, 2, "unknown outcomes must not be blindly retried as a new create")
    }

    func test_unixHostCallsRejectMissingCapability() async throws {
        let dispatcher = JSONRPCDispatcher(router: HostCatalogReceiptRouter())
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: RemoteCodeHostCatalog.botListRPC,
            params: [
                "thread_id": .string(UUID().uuidString),
                "run_id": .string(UUID().uuidString),
            ]
        ))
        XCTAssertEqual(response.error?.code, -32047)
    }

    func test_privateProviderNamespaceIsRejectedOutsideAuthenticatedUnixEntry() async {
        // WHY: host.* aliases must never become a second HTTP/local control
        // plane merely because the caller can spell their private method name.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        let common: [String: JSONValue] = [
            "thread_id": .string(threadID),
            "run_id": .string(runID),
            BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
        ]
        let read = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: RemoteCodeHostCatalog.botListRPC,
            params: common
        )
        let local = await dispatcher.dispatchLocalIPC(read)
        let httpRead = await dispatcher.dispatchHTTP(read, mutationContext: nil)
        XCTAssertEqual(local.error?.code, -32601)
        XCTAssertEqual(httpRead.error?.code, -32601)

        var mutationParams = common
        mutationParams["name"] = .string("Forged HTTP Bot")
        mutationParams["client_request_id"] = .string("forged-http-op")
        let mutation = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: RemoteCodeHostCatalog.botCreateRPC,
            params: mutationParams
        )
        let response = await dispatcher.dispatchHTTP(
            mutation,
            mutationContext: MutationRequestContext(
                ownerFingerprint: "http-owner",
                hostId: "http-host",
                bootEpoch: 1
            )
        )
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(router.createCount, 0, "rejection must happen before receipt claim or domain mutation")
        XCTAssertTrue(router.authorizationMutations.isEmpty)
    }

    func test_privateProviderNamespaceCannotHideInsideUnixBatch() async {
        // WHY: authentication belongs to each named private call; a public
        // read-only batch must not smuggle a host call past the Unix seam.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "rpc.batch",
            params: [
                "calls": .array([
                    .object([
                        "method": .string(RemoteCodeHostCatalog.botListRPC),
                        "params": .object([:]),
                    ]),
                ]),
            ]
        ))
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertTrue(router.authorizationMutations.isEmpty)
    }

    func test_supervisedPeerMethodsAuthenticateAsBearerScopedNotFullAccessMutations() async {
        // WHY: peer consultation and its explicitly granted self-config tools
        // are supervised-run capabilities, not the cross-object host catalog.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        func params(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
            var result: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
            ]
            for (key, value) in extra { result[key] = value }
            return result
        }

        _ = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "bot.peer.list", params: params()
        ))
        _ = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "bot.peer.ask",
            params: params([
                "handle": .string("qa"),
                "prompt": .string("Review this."),
                "reply_mode": .string("consult"),
            ])
        ))
        _ = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: "bot.peer.self_config",
            params: params([
                "tool_name": .string("bot_get_settings"),
                "arguments": .object([:]),
            ])
        ))

        XCTAssertEqual(router.authorizationMutations, [false, false, false])
    }

    func test_legacyUnixCLIReadsRemainOutsideManagedProviderAuthentication() async {
        // WHY: RC2CLI shares this socket and intentionally has no provider-run
        // bearer. The private host.* namespace must not capture its legacy API.
        let dispatcher = JSONRPCDispatcher(router: HostCatalogReceiptRouter())
        let workspaces = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "workspace.list",
            params: [:]
        ))
        XCTAssertNil(workspaces.error)

        let threads = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.thread.list",
            params: [:]
        ))
        XCTAssertNil(threads.error)
    }

    func test_namedHostReadsAndMutationsAreRouted() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        func params(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
            var values: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
            ]
            for (key, value) in extra { values[key] = value }
            return values
        }

        let listed = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: RemoteCodeHostCatalog.botListRPC, params: params()
        ))
        XCTAssertNil(listed.error)
        XCTAssertEqual(listed.result?.objectValue?["bots"]?.arrayValue?.isEmpty, true)

        let created = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: RemoteCodeHostCatalog.botCreateRPC,
            params: params([
                "name": .string("Oliver"),
                "client_request_id": .string("create-1"),
            ])
        ))
        let botID = try XCTUnwrap(created.result?.objectValue?["id"]?.stringValue)
        XCTAssertEqual(router.lastMethod, "create")

        let opened = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: RemoteCodeHostCatalog.botOpenRPC,
            params: params([
                "bot_id": .string(botID),
                "client_request_id": .string("open-1"),
            ])
        ))
        XCTAssertEqual(opened.result?.objectValue?["opened"]?.boolValue, true)

        let skill = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(4),
            method: RemoteCodeHostCatalog.botSkillCreateRPC,
            params: params([
                "bot_id": .string(botID),
                "skill_id": .string("qa"),
                "body": .string("skill-body"),
                "client_request_id": .string("skill-1"),
            ])
        ))
        XCTAssertEqual(skill.result?.objectValue?["body"]?.stringValue, "skill-body")
        XCTAssertEqual(
            skill.result?.objectValue?["digest"]?.stringValue,
            RemoteCodeHostCatalog.bodyDigest("skill-body")
        )

        let viewed = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(5),
            method: RemoteCodeHostCatalog.botSkillViewRPC,
            params: params([
                "bot_id": .string(botID),
                "skill_id": .string("qa"),
            ])
        ))
        XCTAssertEqual(viewed.result?.objectValue?["digest"]?.stringValue, RemoteCodeHostCatalog.bodyDigest("skill-body"))
    }
}

@MainActor
private final class HostCatalogReceiptRouter: FakeRouter, CommandReceiptStateRouting {
    private struct Receipt {
        var owner: String
        var hash: String
        var state: String
        var result: JSONValue?
    }

    var createCount = 0
    var lastMethod = ""
    var markNextUnknown = false
    var authorized = true
    var authorizationMutations: [Bool] = []
    private var receipts: [String: Receipt] = [:]
    private var bots: [String: String] = [:]
    private var skills: [String: String] = [:]

    override func authenticateManagedHostCall(
        threadID: AgentThreadID,
        runID: AgentRunID,
        delegationCapability: String?,
        mutation: Bool,
        method: String
    ) throws {
        authorizationMutations.append(mutation)
        guard authorized else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
        guard let capability = delegationCapability, !capability.isEmpty else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
        _ = method
        _ = threadID
        _ = runID
    }

    override func createHostBot(
        name: String,
        title: String,
        description: String,
        handle: String?,
        soul: String,
        provider: AgentProvider,
        model: String,
        callerRun: AgentRunID
    ) throws -> JSONValue {
        createCount += 1
        lastMethod = "create"
        if markNextUnknown {
            markNextUnknown = false
            throw JSONRPCError.internalError
        }
        let id = UUID().uuidString.lowercased()
        bots[id] = name
        return .object(["id": .string(id), "name": .string(name), "handle": .string(handle ?? name.lowercased())])
    }

    override func listHostBots() throws -> JSONValue {
        lastMethod = "list"
        return .object(["bots": .array(bots.map { id, name in
            .object(["id": .string(id), "name": .string(name)])
        })])
    }

    override func openHostBot(botID: BotID) throws -> JSONValue {
        lastMethod = "open"
        return .object(["bot_id": .string(botID.value.uuidString.lowercased()), "opened": .bool(true)])
    }

    override func sendHostBot(botID: BotID, text: String, conversationID: BotConversationID?) async throws -> JSONValue {
        lastMethod = "send"
        return .object(["enqueued": .bool(true), "bot_id": .string(botID.value.uuidString.lowercased())])
    }

    override func createHostBotThread(botID: BotID, title: String) throws -> JSONValue {
        lastMethod = "thread"
        return .object([
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "conversation_id": .string(UUID().uuidString.lowercased()),
            "title": .string(title),
        ])
    }

    override func createHostBotSkill(
        botID: BotID,
        skillID: String,
        body: String?,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        lastMethod = "skill-create"
        let written = body ?? "default"
        skills["\(botID.value.uuidString.lowercased()):\(skillID)"] = written
        return .object([
            "skill_id": .string(skillID),
            "body": .string(written),
            "digest": .string(RemoteCodeHostCatalog.bodyDigest(written)),
        ])
    }

    override func viewHostBotSkill(
        botID: BotID,
        skillID: String,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        lastMethod = "skill-view"
        let written = skills["\(botID.value.uuidString.lowercased()):\(skillID)"] ?? ""
        return .object([
            "skill_id": .string(skillID),
            "body": .string(written),
            "digest": .string(RemoteCodeHostCatalog.bodyDigest(written)),
        ])
    }

    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        let key = "\(method):\(clientRequestId)"
        if let receipt = receipts[key] {
            guard receipt.owner == ownerFingerprint else { return .ownerMismatch }
            guard receipt.hash == paramsHash else { return .requestMismatch }
            switch receipt.state {
            case "claimed": return .inProgress
            case "committed":
                let data = try JSONEncoder().encode(receipt.result ?? .null)
                return .committed(resultJSON: String(decoding: data, as: UTF8.self))
            default:
                return .unknown
            }
        }
        receipts[key] = Receipt(owner: ownerFingerprint, hash: paramsHash, state: "claimed", result: nil)
        return .claimed
    }

    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {
        let key = "\(method):\(clientRequestId)"
        receipts[key] = Receipt(owner: ownerFingerprint, hash: paramsHash, state: "committed", result: result)
    }

    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        try commitCommandReceipt(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            result: result
        )
        return events.enumerated().map { ordinal, event in
            EventBus.Event(
                seq: minimumEventSequence + Int64(ordinal) + 1,
                kind: event.kind,
                payload: event.payload,
                ts: event.createdAt.timeIntervalSince1970
            )
        }
    }

    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        let key = "\(method):\(clientRequestId)"
        receipts[key] = Receipt(owner: ownerFingerprint, hash: paramsHash, state: "unknown", result: nil)
    }

    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        let key = "\(method):\(clientRequestId)"
        guard let receipt = receipts[key] else { return .absent }
        switch receipt.state {
        case "claimed": return .inProgress
        case "committed": return .committed
        default: return .unknown
        }
    }
}
