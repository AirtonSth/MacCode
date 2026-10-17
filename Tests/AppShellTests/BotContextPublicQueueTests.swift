import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextPublicQueueTests: XCTestCase {
    func testPublicEnqueuePersistsHeldIntentAndCannotDrainAcrossRevocationOrRestart() async throws {
        let parent = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
        let root = parent.appendingPathComponent("PublicContextQueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbPath = root.appendingPathComponent("owned.sqlite").path
        let supportPath = root.appendingPathComponent("support").path
        let context = try AppContext(channel: .debug, dbPathOverride: dbPath,
            appSupportOverride: supportPath, privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false, contextualSecretStore: InMemoryBotSecretStore())
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }

        let bot = try context.botStore.create(name: "Public queue", title: "Public queue", description: "",
            soul: "", provider: .distill, model: "unused", desktopKind: .dockerDesktop)
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general,
            actions: [.read, .send], expectedRevision: 0)
        let thread = AgentThread(title: "Pinned", provider: .distill, model: "unused")
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
        let pin = try context.botStore.createContextualConversation(conversation, newThread: thread,
            hostID: host, context: .general, policyRevision: grant.policyRevision)
        let mutation = MutationRequestContext(ownerFingerprint: "public-queue-owner", hostId: host, bootEpoch: 1)
        let dispatcher = JSONRPCDispatcher(router: router)
        let requestID = UUID().uuidString.lowercased()
        let body = "Hold this user-owned intent"
        let params: [String: JSONValue] = [
            "client_request_id": .string(requestID),
            "host_id": .string("forged-host"),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "context_key": .string("general:v1"),
            "context_version": .number(Double(pin.contextVersion)),
            "policy_revision": .number(Double(pin.policyRevision)),
            "conversation_id": .string(conversation.id.value.uuidString.lowercased()),
            "text": .string(body),
        ]
        let requestData = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("bot.conversation.enqueue"), "params": .object(params)]))
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestData)
        let first = await dispatcher.dispatchHTTP(request, mutationContext: mutation)
        XCTAssertNil(first.error)
        let receipt = try XCTUnwrap(first.result?.objectValue)
        XCTAssertEqual(receipt["status"]?.stringValue, "completed")
        let readback = try XCTUnwrap(receipt["readback"]?.objectValue)
        XCTAssertEqual(readback["enqueued"]?.boolValue, true)
        XCTAssertEqual(readback["execution_available"]?.boolValue, false)
        XCTAssertEqual(readback["requires_user_send"]?.boolValue, true)
        XCTAssertEqual(readback["host_id"]?.stringValue, host)
        XCTAssertEqual(readback["conversation_id"]?.stringValue, conversation.id.value.uuidString.lowercased())
        XCTAssertEqual(readback["thread_id"]?.stringValue, thread.id.value.uuidString.lowercased())
        let queuedID = try XCTUnwrap(readback["queue_id"]?.stringValue)

        let queueRepo = context.queuedMessageRepo
        let initialQueue = try queueRepo.list(threadId: thread.id)
        XCTAssertEqual(initialQueue.count, 1)
        XCTAssertEqual(initialQueue[0].id.value.uuidString.lowercased(), queuedID)
        XCTAssertEqual(initialQueue[0].text, body)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: queuedID, db: context.db))
        let initialDispatch = try XCTUnwrap(queueRepo.dispatch(id: initialQueue[0].id))
        XCTAssertNil(initialDispatch.runId)
        XCTAssertEqual(try context.messageRepo.list(threadId: thread.id).count, 0)
        XCTAssertEqual(try runCount(context, threadID: thread.id), 0)

        let replay = await dispatcher.dispatchHTTP(request, mutationContext: mutation)
        XCTAssertEqual(replay.result?.objectValue?["readback"]?.objectValue?["queue_id"]?.stringValue, queuedID)
        XCTAssertEqual(try queueRepo.list(threadId: thread.id), initialQueue)

        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = false }
        var disabledParams = params
        disabledParams["client_request_id"] = .string(UUID().uuidString.lowercased())
        let disabledData = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("bot.conversation.enqueue"), "params": .object(disabledParams)]))
        let disabledRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: disabledData)
        for _ in 0..<2 {
            let denied = await dispatcher.dispatchHTTP(disabledRequest, mutationContext: mutation)
            XCTAssertEqual(denied.error?.code, -32081, "a definite refusal must not become an unknown execution outcome")
        }
        XCTAssertEqual(try queueRepo.list(threadId: thread.id), initialQueue)
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }

        do {
            try await router.drainNextQueuedAgentMessage(thread: thread.id, recoverPreparedFromPriorProcess: true)
            XCTFail("active context intent must not execute without user send")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("Contextual execution is unavailable"), "\(error)")
        }
        XCTAssertEqual(try queueRepo.list(threadId: thread.id), initialQueue)
        let revoked = try context.botStore.revokeContext(hostID: host, botID: bot.id, context: .general,
            expectedRevision: pin.policyRevision)
        let revokedEnqueue = await dispatcher.dispatchHTTP(disabledRequest, mutationContext: mutation)
        XCTAssertEqual(revokedEnqueue.error?.code, -32084)
        for _ in 0..<2 {
            do {
                try await router.drainNextQueuedAgentMessage(thread: thread.id, recoverPreparedFromPriorProcess: true)
                XCTFail("revoked queue must not be claimed")
            } catch let error as JSONRPCError {
                XCTAssertTrue(error.message.contains("authority is inactive or invalid"), "\(error)")
            }
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: initialQueue[0].id)
                XCTFail("force-now must not execute revoked queue")
            } catch let error as JSONRPCError {
                XCTAssertTrue(error.message.contains("authority is inactive or invalid"), "\(error)")
            }
            await router.reconcileQueuedAgentMessagesOnLaunch()
        }
        try assertUntouched(context, threadID: thread.id, queued: initialQueue, queueID: queuedID, pin: pin, conversationID: conversation.id)

        let regrant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general,
            actions: [.read, .send], expectedRevision: revoked.policyRevision)
        XCTAssertFalse(try context.botStore.authorizes(hostID: host, botID: bot.id, context: .general,
            action: .send, policyRevision: pin.policyRevision))
        XCTAssertTrue(try context.botStore.authorizes(hostID: host, botID: bot.id, context: .general,
            action: .send, policyRevision: regrant.policyRevision))

        let reopened = try AppContext(channel: .debug, dbPathOverride: dbPath, appSupportOverride: supportPath,
            privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false,
            contextualSecretStore: InMemoryBotSecretStore())
        let reopenedRouter = AppCommandRouter(context: reopened)
        reopened.router = reopenedRouter
        let reopenedReplay = await JSONRPCDispatcher(router: reopenedRouter).dispatchHTTP(request, mutationContext: mutation)
        XCTAssertNil(reopenedReplay.error)
        XCTAssertEqual(reopenedReplay.result?.objectValue?["readback"]?.objectValue?["queue_id"]?.stringValue, queuedID)
        do {
            try await reopenedRouter.drainNextQueuedAgentMessage(thread: thread.id, recoverPreparedFromPriorProcess: true)
            XCTFail("receipt replay cannot restore revoked authority")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("authority is inactive or invalid"), "\(error)")
        }
        await reopenedRouter.reconcileQueuedAgentMessagesOnLaunch()
        try assertUntouched(reopened, threadID: thread.id, queued: initialQueue, queueID: queuedID,
            pin: pin, conversationID: conversation.id)
    }

    private func runCount(_ context: AppContext, threadID: AgentThreadID) throws -> Int64 {
        let query = try context.db.prepare("SELECT COUNT(*) FROM agent_runs WHERE thread_id = ? COLLATE NOCASE;")
        defer { query.reset() }
        try query.bind(1, threadID.value.uuidString)
        XCTAssertTrue(try query.step())
        return query.columnInt64(0)
    }

    private func assertUntouched(_ context: AppContext, threadID: AgentThreadID,
        queued: [AgentQueuedMessage], queueID: String, pin: BotConversationContextPin,
        conversationID: BotConversationID) throws {
        XCTAssertEqual(try context.queuedMessageRepo.list(threadId: threadID), queued)
        let dispatch = try XCTUnwrap(context.queuedMessageRepo.dispatch(id: queued[0].id))
        XCTAssertEqual(dispatch.state, .queued)
        XCTAssertNil(dispatch.runId)
        XCTAssertEqual(try context.messageRepo.list(threadId: threadID).count, 0)
        XCTAssertEqual(try runCount(context, threadID: threadID), 0)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: queueID, db: context.db))
        XCTAssertEqual(try context.botStore.conversationContextPin(conversationID: conversationID), pin)
    }
}
