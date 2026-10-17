import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class BotContextQueuedMessageTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let context: AppContext
        let router: AppCommandRouter
        let thread: AgentThread
        let botID: BotID
        let conversation: BotConversation
    }

    private func fixture(_ label: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BotContextQueuedMessageTests-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path, performLaunchRunReconciliation: false)
        let router = AppCommandRouter(context: context)
        context.router = router
        let bot = try context.botStore.create(name: "A", title: "A", description: "", soul: "", provider: .distill, model: "test")
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        var thread = AgentThread(title: "Pinned", provider: .distill, model: "test")
        thread.status = .completed
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: .general, policyRevision: grant.policyRevision)
        return Fixture(root: root, context: context, router: router, thread: thread, botID: bot.id, conversation: conversation)
    }

    private func runCount(_ context: AppContext, threadID: AgentThreadID) throws -> Int64 {
        let query = try context.db.prepare("SELECT COUNT(*) FROM agent_runs WHERE thread_id = ? COLLATE NOCASE;")
        defer { query.reset() }
        try query.bind(1, threadID.value.uuidString)
        XCTAssertTrue(try query.step())
        return query.columnInt64(0)
    }

    func test_validPinnedThreadRefusesPublicGenericSendBeforePreflightAndAttachments() async throws {
        let f = try fixture("valid-send")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var resolved: [[AgentAttachment]] = []
        f.router.sendAgentMessageResolvedAttachmentsProbeForTesting = { resolved.append($0) }

        do {
            _ = try await f.router.sendAgentMessage(thread: f.thread.id, text: "must not send", provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil)
            XCTFail("pinned generic send must fail closed")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602)
            XCTAssertTrue(error.message.contains("Contextual execution is unavailable"))
        }
        do {
            _ = try await f.router.sendAgentMessageRouting(thread: f.thread.id, text: "remote refusal", provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil, serviceTier: nil, interactionMode: nil, modelSelection: nil, providerInstanceId: nil, attachments: [], routing: nil)
            XCTFail("the RPC entry must return a definite pre-write refusal")
        } catch let error as DefiniteMutationRejection {
            XCTAssertEqual((error.underlying as? JSONRPCError)?.code, -32602)
        }

        XCTAssertFalse(f.router.preflightListedProviderSnapshotsForTesting)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertEqual(try f.context.messageRepo.list(threadId: f.thread.id).count, 0)
        XCTAssertTrue(try f.context.queuedMessageRepo.list(threadId: f.thread.id).isEmpty)
        XCTAssertEqual(try runCount(f.context, threadID: f.thread.id), 0)
    }

    func test_pinnedPlanImplementationRefusesBeforeCreatingOrMutatingForEitherThreadMode() async throws {
        for revoked in [false, true] {
            for newThread in [false, true] {
                let f = try fixture("plan-\(revoked)-\(newThread)")
                defer { try? FileManager.default.removeItem(at: f.root) }
                let markdown = "# Supplied plan\nDo not execute."
                try f.context.proposedPlanRepo.upsert(threadId: f.thread.id, plan: AssistantProposedPlan(id: "plan", turnId: "turn", markdown: "stored plan"))
                if revoked {
                    _ = try f.context.botStore.revokeContext(hostID: f.context.liveActivityHostIdentity.serverId, botID: f.botID, context: .general, expectedRevision: 1)
                }
                let threadsBefore = try f.context.threadRepo.list().count
                let planBefore = try f.context.proposedPlanRepo.list(threadId: f.thread.id)
                var resolved: [[AgentAttachment]] = []
                f.router.sendAgentMessageResolvedAttachmentsProbeForTesting = { resolved.append($0) }

                do {
                    _ = try await f.router.implementAgentPlan(thread: f.thread.id, planId: "plan", planMarkdown: markdown, newThread: newThread, provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil)
                    XCTFail("context-pinned plan implementation must refuse")
                } catch let error as JSONRPCError {
                    XCTAssertEqual(error.code, -32602)
                }

                XCTAssertEqual(try f.context.threadRepo.list().count, threadsBefore)
                XCTAssertEqual(try f.context.messageRepo.list(threadId: f.thread.id).count, 0)
                XCTAssertEqual(try runCount(f.context, threadID: f.thread.id), 0)
                XCTAssertEqual(try f.context.proposedPlanRepo.list(threadId: f.thread.id), planBefore)
                XCTAssertFalse(f.router.preflightListedProviderSnapshotsForTesting)
                XCTAssertTrue(resolved.isEmpty)
            }
        }
    }

    func test_revokedHistoricalQueueRemainsUntouchedAcrossDrainForceRecoveryAndReopen() async throws {
        let f = try fixture("revoked-queue")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let attachment = AgentAttachment(path: "/nonexistent/pinned.txt", displayName: "pinned.txt", kind: .file)
        let queued = try f.context.queuedMessageRepo.enqueue(threadId: f.thread.id, text: "historical intent", attachments: [attachment], interactionMode: .default)
        let host = f.context.liveActivityHostIdentity.serverId
        _ = try f.context.botStore.revokeContext(hostID: host, botID: f.botID, context: .general, expectedRevision: 1)
        var resolved: [[AgentAttachment]] = []
        f.router.sendAgentMessageResolvedAttachmentsProbeForTesting = { resolved.append($0) }

        for _ in 0..<2 {
            do {
                try await f.router.drainNextQueuedAgentMessage(thread: f.thread.id, recoverPreparedFromPriorProcess: true)
                XCTFail("revoked queue must be refused before claim")
            } catch let error as JSONRPCError {
                XCTAssertEqual(error.code, -32602)
                XCTAssertTrue(error.message.contains("authority is inactive or invalid"))
            }
            do {
                _ = try await f.router.forceAgentQueuedMessageNow(id: queued.id)
                XCTFail("force-now must fail closed")
            } catch let error as JSONRPCError {
                XCTAssertEqual(error.code, -32602)
                XCTAssertTrue(error.message.contains("authority is inactive or invalid"))
            }
            await f.router.reconcileQueuedAgentMessagesOnLaunch()
        }

        let retained = try XCTUnwrap(f.context.queuedMessageRepo.get(id: queued.id))
        XCTAssertEqual(retained.id, queued.id)
        XCTAssertEqual(retained.threadId, f.thread.id)
        XCTAssertEqual(retained.text, "historical intent")
        XCTAssertEqual(retained.attachments, [attachment])
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertFalse(f.router.preflightListedProviderSnapshotsForTesting)
        XCTAssertEqual(try f.context.messageRepo.list(threadId: f.thread.id).count, 0)
        XCTAssertEqual(try runCount(f.context, threadID: f.thread.id), 0)

        let reopened = try AppContext(channel: .debug, dbPathOverride: f.context.db.path, appSupportOverride: f.root.appendingPathComponent("support").path, performLaunchRunReconciliation: false)
        let reopenedRouter = AppCommandRouter(context: reopened)
        reopened.router = reopenedRouter
        do {
            try await reopenedRouter.drainNextQueuedAgentMessage(thread: f.thread.id, recoverPreparedFromPriorProcess: true)
            XCTFail("restart must not revive revoked authority")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602)
        }
        let reopenedDispatch = try XCTUnwrap(reopened.queuedMessageRepo.dispatch(id: queued.id))
        XCTAssertEqual(reopenedDispatch.state, .queued)
        XCTAssertNil(reopenedDispatch.runId)
        let reopenedQueued = try XCTUnwrap(reopened.queuedMessageRepo.get(id: queued.id))
        XCTAssertEqual(reopenedQueued.text, "historical intent")
        XCTAssertEqual(reopenedQueued.attachments, [attachment])
        XCTAssertEqual(try reopened.messageRepo.list(threadId: f.thread.id).count, 0)
        XCTAssertEqual(try runCount(reopened, threadID: f.thread.id), 0)
    }
}
