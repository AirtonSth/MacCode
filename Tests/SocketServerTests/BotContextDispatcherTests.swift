import Foundation
import XCTest
import CoreModel
import Persistence
@testable import SocketServer

@MainActor
final class BotContextDispatcherTests: XCTestCase {
    func test_authenticatedGrantUsesContextHostAndReplaysWithoutSecondRevision() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bot = try fixture.authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context test"])
        let botID = try XCTUnwrap(bot["bot_id"] as? String)
        let router = BotContextRouter(authority: fixture.authority, receiptRepository: fixture.receipts)
        let dispatcher = JSONRPCDispatcher(router: router)
        let context = MutationRequestContext(ownerFingerprint: "owner-a", hostId: "host-a", bootEpoch: 1)
        let grant = request("bot.context.grant", [
            "client_request_id": .string("context-grant-1"), "host_id": .string("host-b"),
            "bot_id": .string(botID), "context_key": .string("general:v1"),
            "context_version": .number(1), "policy_revision": .number(0),
            "actions": .array([.string("read"), .string("send")]),
        ])

        let first = await dispatcher.dispatchHTTP(grant, mutationContext: context)
        XCTAssertNil(first.error)
        XCTAssertEqual(router.dispatchCount, 1)
        XCTAssertEqual(router.lastPairedParams?["host_id"]?.stringValue, "host-a")
        let authorityReplay = try fixture.authority.dispatch(method: "bot.context.grant", params: try XCTUnwrap(router.lastPairedParams).mapValues(\.foundationValue))
        XCTAssertEqual(authorityReplay["status"] as? String, "completed")
        let bindingRows = try XCTUnwrap(try fixture.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]])
        let binding = try XCTUnwrap(bindingRows.first)
        XCTAssertEqual(binding["policy_revision"] as? Int64, 1)
        let attackerBindings = try fixture.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-b", "bot_id": botID])["bindings"] as? [[String: Any]]
        XCTAssertEqual(attackerBindings?.count, 0)

        let replay = await dispatcher.dispatchHTTP(grant, mutationContext: context)
        XCTAssertNil(replay.error)
        XCTAssertEqual(router.dispatchCount, 1)
        let replayBindings = try XCTUnwrap(try fixture.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]])
        XCTAssertEqual(replayBindings.first?["policy_revision"] as? Int64, 1)

        let persistedGrant = grant
        let persistedFirst = await dispatcher.dispatchHTTP(persistedGrant, mutationContext: context)
        XCTAssertNil(persistedFirst.error)
        let reopened = try fixture.reopen()
        let reopenedRouter = BotContextRouter(authority: reopened.authority, receiptRepository: reopened.receipts)
        let reopenedDispatcher = JSONRPCDispatcher(router: reopenedRouter)
        let persistedReplay = await reopenedDispatcher.dispatchHTTP(persistedGrant, mutationContext: context)
        XCTAssertNil(persistedReplay.error)
        XCTAssertEqual(reopenedRouter.dispatchCount, 0)
        let durableBindings = try XCTUnwrap(try reopened.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]])
        XCTAssertEqual(durableBindings.first?["policy_revision"] as? Int64, 1)

        var authorityReplayParams = try XCTUnwrap(persistedGrant.params).mapValues(\.foundationValue)
        authorityReplayParams["host_id"] = "host-a"
        let domainReplay = try reopened.authority.dispatch(method: "bot.context.grant", params: authorityReplayParams)
        XCTAssertEqual(domainReplay["status"] as? String, "completed")
        let domainReplayBindings = try XCTUnwrap(try reopened.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]])
        XCTAssertEqual(domainReplayBindings.first?["policy_revision"] as? Int64, 1)

        let revoke = request("bot.context.revoke", [
            "client_request_id": .string("revoke-1"), "host_id": .string("host-b"),
            "bot_id": .string(botID), "context_key": .string("general:v1"),
            "context_version": .number(1), "policy_revision": .number(1),
        ])
        let revoked = await dispatcher.dispatchHTTP(revoke, mutationContext: context)
        XCTAssertNil(revoked.error)
        let afterRevoke = try fixture.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]]
        XCTAssertEqual(afterRevoke?.first?["state"] as? String, "revoked")

        for invalidVersion: JSONValue in [.null, .number(1.5)] {
            var invalid = grant.params ?? [:]
            invalid["client_request_id"] = .string("invalid-\(UUID().uuidString)")
            invalid["context_version"] = invalidVersion
            let response = await dispatcher.dispatchHTTP(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "bot.context.grant", params: invalid), mutationContext: context)
            XCTAssertNil(response.error)
            XCTAssertEqual(response.result?.objectValue?["status"]?.stringValue, "failed")
            XCTAssertEqual(response.result?.objectValue?["readback"]?.objectValue?["error_code"]?.intValue, -32602)
        }
        var stale = grant.params ?? [:]
        stale["client_request_id"] = .string("stale-context-policy")
        stale["policy_revision"] = .number(99)
        let staleResponse = await dispatcher.dispatchHTTP(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "bot.context.grant", params: stale), mutationContext: context)
        XCTAssertNil(staleResponse.error)
        XCTAssertEqual(staleResponse.result?.objectValue?["status"]?.stringValue, "failed")
        XCTAssertEqual(staleResponse.result?.objectValue?["readback"]?.objectValue?["error_code"]?.intValue, -32602)
        let unchanged = try fixture.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]]
        XCTAssertEqual(unchanged?.first?["state"] as? String, "revoked")
        XCTAssertEqual(unchanged?.first?["policy_revision"] as? Int64, 2)
    }

    func test_contextualConversationCreatePersistsAndReplaysThroughDispatcher() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bot = try fixture.authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context test"])
        let botID = try XCTUnwrap(bot["bot_id"] as? String)
        let router = BotContextRouter(authority: fixture.authority, receiptRepository: fixture.receipts)
        let dispatcher = JSONRPCDispatcher(router: router)
        let context = MutationRequestContext(ownerFingerprint: "owner-a", hostId: "host-a", bootEpoch: 1)
        _ = try fixture.authority.dispatch(method: "bot.routing.set", params: ["client_request_id": "route-create", "bot_id": botID, "provider": "distill", "model": "test-main", "routing_mode": "explicit"])
        let grant = request("bot.context.grant", ["client_request_id": .string("grant-create"), "bot_id": .string(botID), "context_key": .string("general:v1"), "context_version": .number(1), "policy_revision": .number(0), "actions": .array([.string("read"), .string("send")])])
        let grantResponse = await dispatcher.dispatchHTTP(grant, mutationContext: context)
        XCTAssertNil(grantResponse.error)
        let create = request("bot.conversation.create", ["client_request_id": .string("create-contextual"), "bot_id": .string(botID), "context_key": .string("general:v1"), "context_version": .number(1), "policy_revision": .number(1)])
        var forged = create.params ?? [:]
        forged["host_id"] = .string("attacker")
        let forgedCreate = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: create.method, params: forged)
        let first = await dispatcher.dispatchHTTP(forgedCreate, mutationContext: context)
        XCTAssertNil(first.error)
        let envelope = try XCTUnwrap(first.result?.objectValue)
        XCTAssertEqual(envelope["status"]?.stringValue, "completed")
        XCTAssertEqual(envelope["bot_id"]?.stringValue, botID)
        let result = try XCTUnwrap(envelope["readback"]?.objectValue)
        XCTAssertEqual(Set(result.keys), Set(["conversation_id", "thread_id", "host_id", "context_key", "context_version", "policy_revision", "title"]))
        let conversationID = try XCTUnwrap(result["conversation_id"]?.stringValue)
        let threadID = try XCTUnwrap(result["thread_id"]?.stringValue)
        XCTAssertEqual(result["host_id"]?.stringValue, "host-a")
        XCTAssertEqual(result["context_key"]?.stringValue, "general:v1")
        XCTAssertEqual(result["context_version"]?.intValue, 1)
        XCTAssertEqual(result["policy_revision"]?.intValue, 1)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM bot_conversations;"), 1)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM agent_threads;"), 1)
        if let capturePath = ProcessInfo.processInfo.environment["RC2_CONTEXT_CREATE_CAPTURE_PATH"], let resultValue = first.result?.foundationValue {
            let data = try JSONSerialization.data(withJSONObject: resultValue, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: capturePath), options: .atomic)
        }
        let threadIDValue = try XCTUnwrap(UUID(uuidString: threadID))
        let persistedThread = try XCTUnwrap(AgentThreadRepository(db: fixture.db).get(id: AgentThreadID(threadIDValue)))
        XCTAssertEqual(persistedThread.actor, .bot(BotID(try XCTUnwrap(UUID(uuidString: botID)))))
        XCTAssertEqual(persistedThread.executionTarget, .vm)
        XCTAssertTrue(try XCTUnwrap(AgentThreadRepository(db: fixture.db).guestPlacement(of: AgentThreadID(threadIDValue))).runsInGuest)
        XCTAssertNil(persistedThread.workspaceId)
        XCTAssertNil(persistedThread.providerThreadId)
        let pin = try fixture.db.prepare("SELECT host_id, context_key, policy_revision FROM bot_conversation_contexts WHERE conversation_id=?;")
        try pin.bind(1, conversationID)
        XCTAssertTrue(try pin.step())
        XCTAssertEqual(pin.columnText(0), "host-a")
        XCTAssertEqual(pin.columnText(1), "general:v1")
        XCTAssertEqual(pin.columnInt64(2), 1)
        let replay = await dispatcher.dispatchHTTP(forgedCreate, mutationContext: context)
        XCTAssertEqual(replay.result?.objectValue?["readback"]?.objectValue?["conversation_id"]?.stringValue, conversationID)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM bot_conversations;"), 1)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM agent_threads;"), 1)
        let reopened = try fixture.reopen()
        let reopenedRouter = BotContextRouter(authority: reopened.authority, receiptRepository: reopened.receipts)
        let reopenedDispatcher = JSONRPCDispatcher(router: reopenedRouter)
        let persisted = await reopenedDispatcher.dispatchHTTP(forgedCreate, mutationContext: context)
        XCTAssertEqual(persisted.result?.objectValue?["readback"]?.objectValue?["thread_id"]?.stringValue, threadID)
        XCTAssertEqual(reopenedRouter.dispatchCount, 0)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM bot_conversations;"), 1)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM agent_threads;"), 1)
    }

    func test_contextualCreationRevalidatesPolicyAndSeparatesWorkspacePairs() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bot = try fixture.authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context matrix"])
        let botID = try XCTUnwrap(bot["bot_id"] as? String)
        let router = BotContextRouter(authority: fixture.authority, receiptRepository: fixture.receipts)
        let dispatcher = JSONRPCDispatcher(router: router)
        let owner = MutationRequestContext(ownerFingerprint: "owner-a", hostId: "host-a", bootEpoch: 1)
        func scoped(_ key: String = "general:v1", revision: Int = 1) -> [String: JSONValue] {
            ["client_request_id": .string(UUID().uuidString), "bot_id": .string(botID),
             "context_key": .string(key), "context_version": .number(1), "policy_revision": .number(Double(revision))]
        }
        func grant(_ key: String = "general:v1", revision: Int = 0, send: Bool = true) async throws {
            var params = scoped(key, revision: revision)
            params["actions"] = .array((send ? ["read", "send"] : ["read"]).map(JSONValue.string))
            let response = await dispatcher.dispatchHTTP(request("bot.context.grant", params), mutationContext: owner)
            XCTAssertNil(response.error)
            XCTAssertEqual(response.result?.objectValue?["status"]?.stringValue, "completed")
        }
        func denied(_ params: [String: JSONValue]) async throws {
            let response = await dispatcher.dispatchHTTP(request("bot.conversation.create", params), mutationContext: owner)
            XCTAssertTrue(response.error != nil || response.result?.objectValue?["status"]?.stringValue == "failed")
            XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM bot_conversations;"), 0)
            XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM agent_threads;"), 0)
        }
        try await grant()
        // A pinned thread must not bypass the desk's explicit Main-model requirement.
        try await denied(scoped())
        _ = try fixture.authority.dispatch(method: "bot.routing.set", params: ["client_request_id": "route-matrix", "bot_id": botID, "provider": "distill", "model": "test-main"])
        var invalid = scoped()
        invalid["context_version"] = .number(1.5)
        try await denied(invalid)
        invalid = scoped()
        invalid.removeValue(forKey: "context_key")
        try await denied(invalid)
        try await denied(scoped(revision: 99))
        let revoked = await dispatcher.dispatchHTTP(request("bot.context.revoke", scoped()), mutationContext: owner)
        XCTAssertEqual(revoked.result?.objectValue?["status"]?.stringValue, "completed")
        try await denied(scoped())
        try await grant(revision: 2, send: false)
        try await denied(scoped(revision: 3))
        let before = router.dispatchCount
        let unix = await dispatcher.dispatchUnixSocket(request("bot.conversation.create", scoped(revision: 3)))
        XCTAssertNotNil(unix.error)
        let unauthenticated = await dispatcher.dispatchHTTP(request("bot.conversation.create", scoped(revision: 3)), mutationContext: nil)
        XCTAssertNotNil(unauthenticated.error)
        XCTAssertEqual(router.dispatchCount, before)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM agent_threads;"), 0)

        let workspaces = [WorkspaceID(), WorkspaceID()]
        var conversationIDs = Set<String>()
        var threadIDs = Set<String>()
        for workspace in workspaces {
            let context = BotContext.workspace(workspace)
            try await grant(context.storageKey)
            let response = await dispatcher.dispatchHTTP(request("bot.conversation.create", scoped(context.storageKey)), mutationContext: owner)
            XCTAssertNil(response.error)
            XCTAssertEqual(response.result?.objectValue?["status"]?.stringValue, "completed")
            let readback = try XCTUnwrap(response.result?.objectValue?["readback"]?.objectValue)
            let conversationID = try XCTUnwrap(readback["conversation_id"]?.stringValue)
            let threadID = try XCTUnwrap(readback["thread_id"]?.stringValue)
            conversationIDs.insert(conversationID)
            threadIDs.insert(threadID)
            let stored = try XCTUnwrap(AgentThreadRepository(db: fixture.db).get(id: AgentThreadID(try XCTUnwrap(UUID(uuidString: threadID)))))
            XCTAssertEqual(stored.workspaceId, workspace)
            XCTAssertEqual(stored.model, "test-main")
            XCTAssertNil(stored.providerThreadId)
            let pin = try XCTUnwrap(BotStore(db: fixture.db).conversationContextPin(conversationID: BotConversationID(try XCTUnwrap(UUID(uuidString: conversationID)))))
            XCTAssertEqual(pin.context, context)
            XCTAssertEqual(pin.hostID, "host-a")
        }
        XCTAssertEqual(conversationIDs.count, 2)
        XCTAssertEqual(threadIDs.count, 2)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM bot_conversations;"), 2)
        XCTAssertEqual(try fixture.rowCount("SELECT COUNT(*) FROM agent_threads;"), 2)
    }

    func test_unixSocketRejectsContextGrantBeforeAuthorityDispatch() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bot = try fixture.authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context test"])
        let botID = try XCTUnwrap(bot["bot_id"] as? String)
        let router = BotContextRouter(authority: fixture.authority, receiptRepository: fixture.receipts)
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(request("bot.context.grant", [
            "client_request_id": .string("unix-grant"), "host_id": .string("host-a"),
            "bot_id": .string(botID), "context_key": .string("general:v1"),
            "context_version": .number(1), "policy_revision": .number(0),
            "actions": .array([.string("read")]),
        ]))
        XCTAssertEqual(response.error?.code, -32098)
        XCTAssertEqual(router.dispatchCount, 0)
        let bindings = try fixture.authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]]
        XCTAssertEqual(bindings?.count, 0)
    }

    func test_scopedConversationForkDeniedBeforeRouterWithOrWithoutGrant() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bot = try fixture.authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context test"])
        let botID = try XCTUnwrap(bot["bot_id"] as? String)
        let router = BotContextRouter(authority: fixture.authority, receiptRepository: fixture.receipts)
        let dispatcher = JSONRPCDispatcher(router: router)
        let context = MutationRequestContext(ownerFingerprint: "owner-a", hostId: "host-a", bootEpoch: 1)
        let base: [String: JSONValue] = [
            "client_request_id": .string("fork-missing-grant"), "bot_id": .string(botID),
            "conversation_id": .string(UUID().uuidString.lowercased()),
            "context_key": .string("general:v1"), "context_version": .number(1), "policy_revision": .number(1),
        ]
        let before = router.dispatchCount
        let missingGrant = await dispatcher.dispatchHTTP(request("bot.conversation.fork", base), mutationContext: context)
        XCTAssertNotNil(missingGrant.error)
        XCTAssertEqual(router.dispatchCount, before)

        let grantParams: [String: JSONValue] = [
            "client_request_id": .string("fork-grant"), "bot_id": .string(botID),
            "context_key": .string("general:v1"), "context_version": .number(1),
            "policy_revision": .number(0), "actions": .array([.string("read"), .string("send")]),
        ]
        let grantResponse = await dispatcher.dispatchHTTP(request("bot.context.grant", grantParams), mutationContext: context)
        XCTAssertNil(grantResponse.error)

        var validGrantForkParams = base
        validGrantForkParams["client_request_id"] = .string("fork-valid-grant")
        validGrantForkParams["policy_revision"] = .number(1)
        let afterGrant = router.dispatchCount
        let validGrant = await dispatcher.dispatchHTTP(request("bot.conversation.fork", validGrantForkParams), mutationContext: context)
        XCTAssertNotNil(validGrant.error)
        XCTAssertEqual(router.dispatchCount, afterGrant)
    }

    private func request(_ method: String, _ params: [String: JSONValue]) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: params)
    }
}

private struct Fixture {
    let directory: URL
    let dbPath: String
    let authority: BotRemoteControlAuthority
    let receipts: CommandReceiptRepository
    let db: SQLiteDB

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bot-context-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPath = directory.appendingPathComponent("authority.sqlite").path
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        self.db = db
        authority = Self.authority(db: db, directory: directory)
        receipts = CommandReceiptRepository(db: db)
    }

    func rowCount(_ sql: String) throws -> Int64 {
        let statement = try db.prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.columnInt64(0)
    }

    func reopen() throws -> (authority: BotRemoteControlAuthority, receipts: CommandReceiptRepository, db: SQLiteDB) {
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        return (Self.authority(db: db, directory: directory), CommandReceiptRepository(db: db), db)
    }

    private static func authority(db: SQLiteDB, directory: URL) -> BotRemoteControlAuthority {
        BotRemoteControlAuthority(db: db, store: BotStore(db: db), settings: SettingsStore(db: db), appSupportDirectory: directory.appendingPathComponent("support", isDirectory: true))
    }
}

@MainActor
private final class BotContextRouter: FakeRouter, CommandReceiptStateRouting {
    let authority: BotRemoteControlAuthority
    let receipts: CommandReceiptRepository
    private(set) var lastPairedParams: [String: JSONValue]?
    private(set) var dispatchCount = 0

    init(authority: BotRemoteControlAuthority, receiptRepository: CommandReceiptRepository) {
        self.authority = authority
        self.receipts = receiptRepository
    }

    override func dispatchPairedBotRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        dispatchCount += 1
        lastPairedParams = params
        do {
            return try JSONValue.from(any: authority.dispatch(method: method, params: params.mapValues(\.foundationValue)))
        } catch let error as BotRemoteControlAuthority.Error {
            if let requestID = params["client_request_id"]?.stringValue,
               let failed = try? authority.dispatch(method: "bot.receipt.status", params: ["client_request_id": requestID]),
               failed["status"] as? String == "failed" {
                return try JSONValue.from(any: failed)
            }
            throw JSONRPCError(code: error.code, message: error.message)
        }
    }

    func claimCommandReceipt(method: String, clientRequestId: String, ownerFingerprint: String, paramsHash: String) throws -> CommandReceiptClaimResult {
        try repository.claim(method: method, clientRequestId: clientRequestId, ownerFingerprint: ownerFingerprint, paramsHash: paramsHash)
    }
    func commitCommandReceipt(method: String, clientRequestId: String, ownerFingerprint: String, paramsHash: String, result: JSONValue) throws {
        try repository.commit(method: method, clientRequestId: clientRequestId, ownerFingerprint: ownerFingerprint, paramsHash: paramsHash, resultJSON: Self.json(result))
    }
    func finalizeCommandReceipt(method: String, clientRequestId: String, ownerFingerprint: String, paramsHash: String, result: JSONValue, events: [EventBus.MutationEventIntent], minimumEventSequence: Int64) throws -> [EventBus.Event] {
        let persistedEvents = try events.map { event in
            CommandReceiptEventIntent(kind: event.kind.rawValue, payloadJSON: try Self.json(event.payload), createdAt: event.createdAt)
        }
        let rows = try repository.finalize(method: method, clientRequestId: clientRequestId, ownerFingerprint: ownerFingerprint, paramsHash: paramsHash, resultJSON: Self.json(result), events: persistedEvents, minimumEventSequence: minimumEventSequence)
        return try rows.map { row in
            guard let payload = row.payloadJSON.data(using: .utf8), let decoded = JSONValue.decode(from: payload) else { throw JSONRPCError.internalError }
            return EventBus.Event(seq: row.seq, kind: row.kind, payload: decoded, ts: row.createdAt.timeIntervalSince1970)
        }
    }
    func markCommandReceiptUnknown(method: String, clientRequestId: String, ownerFingerprint: String, paramsHash: String) throws {
        try repository.markUnknown(method: method, clientRequestId: clientRequestId, ownerFingerprint: ownerFingerprint, paramsHash: paramsHash)
    }
    func releaseCommandReceiptClaim(method: String, clientRequestId: String, ownerFingerprint: String, paramsHash: String) throws {
        try repository.releaseClaim(method: method, clientRequestId: clientRequestId, ownerFingerprint: ownerFingerprint, paramsHash: paramsHash)
    }
    func commandReceiptStatus(method: String, clientRequestId: String, ownerFingerprint: String) throws -> CommandReceiptStatusResult {
        try repository.status(method: method, clientRequestId: clientRequestId, ownerFingerprint: ownerFingerprint)
    }

    private var repository: CommandReceiptRepository { receipts }
    private static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }
    static func from(any: Any) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
